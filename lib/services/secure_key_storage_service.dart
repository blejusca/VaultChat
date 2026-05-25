import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// All sensitive secrets stored via Android Keystore / iOS Secure Enclave.
/// Nothing sensitive lives in plain SharedPreferences.
class SecureKeyStorageService {
  SecureKeyStorageService._();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      // resetOnError: true ensures that if EncryptedSharedPreferences fails
      // to decrypt (e.g. after factory reset or Keystore corruption on some
      // Android 10/11 devices like Nokia 5.4), the storage resets gracefully
      // instead of crashing. The user will need to restore from backup.
      resetOnError: true,
    ),
  );

  // ── Private key ────────────────────────────────────────────────────────────
  static const String privateKeyKey      = 'vaultchat_private_key_hex_v2';
  static const String legacyPrivateKeyKey = 'nostr_private_key_hex';

  // ── Hive AES key ───────────────────────────────────────────────────────────
  static const String hiveAesKeyKey = 'vaultchat_hive_aes_key_v1';

  // ── PIN (hash + salt moved here from SharedPreferences) ────────────────────
  static const String pinHashKey = 'vaultchat_pin_hash_v2';
  static const String pinSaltKey = 'vaultchat_pin_salt_v2';

  // ── Identity activation timestamp ──────────────────────────────────────────
  // Tracks when the current identity was created or last restored.
  // Used as the 'since' filter for relay subscriptions to prevent
  // historical message replay after identity deletion and recreation.
  //
  // INTENTIONAL: Stored in SharedPreferences (not Keystore) because:
  //   1. It is NOT sensitive data — it's a Unix timestamp, not a secret.
  //   2. If lost after Keystore reset (rare), the app falls back to 31-day
  //      window, which is acceptable and safe.
  //   3. Storing it in Keystore would risk losing it alongside the keys
  //      on certain Android 10/11 devices with Keystore corruption.
  static const String _identityActivatedAtKey = 'vaultchat_identity_activated_at_v1';

  // ── Private key ────────────────────────────────────────────────────────────

  static Future<String?> readPrivateKey() async {
    final secureValue = await _secureStorage.read(key: privateKeyKey);
    if (secureValue != null && secureValue.trim().isNotEmpty) {
      return secureValue.trim();
    }

    // Migrate from legacy SharedPreferences location (v1 → v2).
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(legacyPrivateKeyKey)?.trim();
    if (legacy != null && legacy.isNotEmpty) {
      await writePrivateKey(legacy);
      await prefs.remove(legacyPrivateKeyKey);
      return legacy;
    }

    return null;
  }

  static Future<void> writePrivateKey(String privateKeyHex) async {
    await _secureStorage.write(
      key: privateKeyKey,
      value: privateKeyHex.trim(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(legacyPrivateKeyKey);
  }

  static Future<void> deletePrivateKey() async {
    await _secureStorage.delete(key: privateKeyKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(legacyPrivateKeyKey);
  }

  // ── Hive AES key ───────────────────────────────────────────────────────────

  static Future<List<int>> readOrCreateHiveAesKey() async {
    final stored = await _secureStorage.read(key: hiveAesKeyKey);
    if (stored != null && stored.trim().isNotEmpty) {
      final decoded = base64Decode(stored.trim());
      if (decoded.length == 32) return decoded;
    }

    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    await _secureStorage.write(key: hiveAesKeyKey, value: base64Encode(key));
    return key;
  }

  static Future<void> deleteHiveAesKey() async {
    await _secureStorage.delete(key: hiveAesKeyKey);
  }

  // ── PIN hash + salt ────────────────────────────────────────────────────────

  static Future<String?> readPinHash() async {
    return _secureStorage.read(key: pinHashKey);
  }

  static Future<String?> readPinSalt() async {
    return _secureStorage.read(key: pinSaltKey);
  }

  static Future<void> writePinHashAndSalt({
    required String hash,
    required String salt,
  }) async {
    await _secureStorage.write(key: pinHashKey, value: hash);
    await _secureStorage.write(key: pinSaltKey, value: salt);
    // Clean up any legacy SharedPreferences pin data.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('secure_chat_pin_hash_v2');
    await prefs.remove('secure_chat_pin_salt_v2');
    await prefs.remove('secure_chat_pin_hash_v1');
    await prefs.remove('secure_chat_pin_salt_v1');
    await prefs.remove('secure_chat_pin');
  }

  static Future<void> deletePinHashAndSalt() async {
    await _secureStorage.delete(key: pinHashKey);
    await _secureStorage.delete(key: pinSaltKey);
  }

  // ── Identity activation timestamp ──────────────────────────────────────────

  static Future<DateTime?> readIdentityActivatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_identityActivatedAtKey);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static Future<void> writeIdentityActivatedAt(DateTime activatedAt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _identityActivatedAtKey,
      activatedAt.millisecondsSinceEpoch,
    );
  }

  static Future<void> deleteIdentityActivatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_identityActivatedAtKey);
  }

  // ── Wipe everything ────────────────────────────────────────────────────────

  static Future<void> deleteAllSecrets() async {
    await deletePrivateKey();
    await deleteHiveAesKey();
    await deletePinHashAndSalt();
    await deleteIdentityActivatedAt();
  }
}
