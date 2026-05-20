import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_storage_service.dart';
import 'contact_storage_service.dart';
import 'secure_key_storage_service.dart';

class PinLockService {
  // Legacy SharedPreferences keys — used only during migration read.
  static const String _legacyPlainPinKey   = 'secure_chat_pin';
  static const String _legacyPinHashKey    = 'secure_chat_pin_hash_v1';
  static const String _legacyPinSaltKey    = 'secure_chat_pin_salt_v1';
  static const String _legacyPinHashV2Key  = 'secure_chat_pin_hash_v2';
  static const String _legacyPinSaltV2Key  = 'secure_chat_pin_salt_v2';

  // Attempt counter stays in SharedPreferences (not sensitive).
  static const String _pinAttemptsKey = 'secure_chat_pin_attempts_v1';

  static const int maxAttempts  = 10;
  static const int pinLength    = 6;
  static const int _pinIterations = 210000;

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<bool> hasPin() async {
    // Check secure storage first (current location).
    final secureHash = await SecureKeyStorageService.readPinHash();
    if (secureHash != null && secureHash.isNotEmpty) return true;

    // Fall back to legacy SharedPreferences locations for migration detection.
    final prefs = await SharedPreferences.getInstance();
    final legacyHashV2 = prefs.getString(_legacyPinHashV2Key);
    final legacyHashV1 = prefs.getString(_legacyPinHashKey);
    final legacyPin    = prefs.getString(_legacyPlainPinKey);

    return (legacyHashV2 != null && legacyHashV2.isNotEmpty) ||
           (legacyHashV1 != null && legacyHashV1.isNotEmpty) ||
           (legacyPin    != null && legacyPin.isNotEmpty);
  }

  Future<int> failedAttempts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_pinAttemptsKey) ?? 0;
  }

  Future<void> createPin(String pin) async {
    _validatePinFormat(pin);

    final salt = _generateSalt();
    final hash = await _hashPin(pin, salt);

    // Store in Keystore-backed secure storage.
    await SecureKeyStorageService.writePinHashAndSalt(hash: hash, salt: salt);

    // Reset attempt counter.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pinAttemptsKey, 0);
  }

  Future<PinVerifyResult> verifyPin(String pin) async {
    _validatePinFormat(pin);

    bool valid = false;

    // ── 1. Current secure storage location ───────────────────────────────────
    final secureHash = await SecureKeyStorageService.readPinHash();
    final secureSalt = await SecureKeyStorageService.readPinSalt();

    if (secureHash != null && secureSalt != null) {
      valid = await _constantTimeEqualsString(
        await _hashPin(pin, secureSalt),
        secureHash,
      );
    } else {
      // ── 2. Legacy SharedPreferences migration path ────────────────────────
      valid = await _verifyLegacy(pin);

      // Promote to secure storage on successful legacy verification.
      if (valid) {
        await createPin(pin);
      }
    }

    final prefs = await SharedPreferences.getInstance();

    if (valid) {
      await prefs.setInt(_pinAttemptsKey, 0);
      return const PinVerifyResult(
        success: true,
        wiped: false,
        attemptsLeft: maxAttempts,
      );
    }

    final attempts = (prefs.getInt(_pinAttemptsKey) ?? 0) + 1;
    await prefs.setInt(_pinAttemptsKey, attempts);

    if (attempts >= maxAttempts) {
      await wipeAllApplicationData();
      return const PinVerifyResult(
        success: false,
        wiped: true,
        attemptsLeft: 0,
      );
    }

    return PinVerifyResult(
      success: false,
      wiped: false,
      attemptsLeft: maxAttempts - attempts,
    );
  }

  Future<void> wipeAllApplicationData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await ConversationStorageService.deleteAllLocalData();
    await ContactStorageService.deleteAllLocalData();
    await SecureKeyStorageService.deleteAllSecrets();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  Future<String> _hashPin(String pin, String salt) async {
    final algorithm = cryptography.Pbkdf2(
      macAlgorithm: cryptography.Hmac.sha256(),
      iterations: _pinIterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(pin)),
      nonce: utf8.encode('vaultchat-pin-v2:$salt'),
    );
    return base64UrlEncode(await key.extractBytes());
  }

  /// Verifies against legacy storage formats (SharedPreferences).
  /// Uses constant-time comparison where hashes are available to avoid
  /// timing side-channels. The plain-pin path uses constant-time bytes compare.
  Future<bool> _verifyLegacy(String pin) async {
    final prefs = await SharedPreferences.getInstance();

    // Legacy v2: PBKDF2 hash stored in SharedPreferences.
    final hashV2 = prefs.getString(_legacyPinHashV2Key);
    final saltV2 = prefs.getString(_legacyPinSaltV2Key);
    if (hashV2 != null && saltV2 != null) {
      return _constantTimeEqualsString(await _hashPin(pin, saltV2), hashV2);
    }

    // Legacy v1: simple SHA-256 chain.
    final hashV1 = prefs.getString(_legacyPinHashKey);
    final saltV1 = prefs.getString(_legacyPinSaltKey);
    if (hashV1 != null && saltV1 != null) {
      return _constantTimeEqualsString(_legacyHashPin(pin, saltV1), hashV1);
    }

    // Legacy v0: PIN stored in plaintext — constant-time bytes compare.
    final legacyPin = prefs.getString(_legacyPlainPinKey);
    if (legacyPin != null) {
      return _constantTimeEqualsBytes(
        utf8.encode(pin),
        utf8.encode(legacyPin),
      );
    }

    return false;
  }

  String _legacyHashPin(String pin, String salt) {
    List<int> digest = utf8.encode('$salt:$pin:securechat-pin-v1').toList();
    for (var i = 0; i < 12000; i++) {
      digest = sha256.convert(digest).bytes.toList();
    }
    return base64UrlEncode(digest);
  }

  Future<bool> _constantTimeEqualsString(String a, String b) async {
    return _constantTimeEqualsBytes(utf8.encode(a), utf8.encode(b));
  }

  bool _constantTimeEqualsBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  void _validatePinFormat(String pin) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw ArgumentError('PIN-ul trebuie sa aiba exact 6 cifre.');
    }
  }
}

class PinVerifyResult {
  final bool success;
  final bool wiped;
  final int attemptsLeft;

  const PinVerifyResult({
    required this.success,
    required this.wiped,
    required this.attemptsLeft,
  });
}
