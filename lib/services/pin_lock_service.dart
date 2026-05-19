import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_storage_service.dart';
import 'contact_storage_service.dart';

class PinLockService {
  static const String _pinHashKey = 'secure_chat_pin_hash_v1';
  static const String _pinSaltKey = 'secure_chat_pin_salt_v1';
  static const String _pinAttemptsKey = 'secure_chat_pin_attempts_v1';
  static const String _legacyPlainPinKey = 'secure_chat_pin';

  static const int maxAttempts = 10;
  static const int pinLength = 6;

  Future<bool> hasPin() async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString(_pinHashKey);
    final legacyPin = prefs.getString(_legacyPlainPinKey);
    return (hash != null && hash.isNotEmpty) ||
        (legacyPin != null && legacyPin.isNotEmpty);
  }

  Future<int> failedAttempts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_pinAttemptsKey) ?? 0;
  }

  Future<void> createPin(String pin) async {
    _validatePinFormat(pin);

    final prefs = await SharedPreferences.getInstance();
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);

    await prefs.setString(_pinSaltKey, salt);
    await prefs.setString(_pinHashKey, hash);
    await prefs.setInt(_pinAttemptsKey, 0);
    await prefs.remove(_legacyPlainPinKey);
  }

  Future<PinVerifyResult> verifyPin(String pin) async {
    _validatePinFormat(pin);

    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_pinHashKey);
    final salt = prefs.getString(_pinSaltKey);

    bool valid = false;

    if (storedHash != null && salt != null) {
      valid = _hashPin(pin, salt) == storedHash;
    } else {
      final legacyPin = prefs.getString(_legacyPlainPinKey);
      valid = legacyPin != null && legacyPin == pin;

      if (valid) {
        await createPin(pin);
      }
    }

    if (valid) {
      await prefs.setInt(_pinAttemptsKey, 0);
      return const PinVerifyResult(success: true, wiped: false, attemptsLeft: maxAttempts);
    }

    final attempts = (prefs.getInt(_pinAttemptsKey) ?? 0) + 1;
    await prefs.setInt(_pinAttemptsKey, attempts);

    if (attempts >= maxAttempts) {
      await wipeAllApplicationData();
      return const PinVerifyResult(success: false, wiped: true, attemptsLeft: 0);
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
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _hashPin(String pin, String salt) {
    List<int> digest = utf8.encode('$salt:$pin:securechat-pin-v1').toList();

    for (var i = 0; i < 12000; i++) {
      digest = sha256.convert(digest).bytes.toList();
    }

    return base64UrlEncode(digest);
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
