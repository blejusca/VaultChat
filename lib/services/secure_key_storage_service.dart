import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecureKeyStorageService {
  SecureKeyStorageService._();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static const String privateKeyKey = 'vaultchat_private_key_hex_v2';
  static const String hiveAesKeyKey = 'vaultchat_hive_aes_key_v1';
  static const String legacyPrivateKeyKey = 'nostr_private_key_hex';

  static Future<String?> readPrivateKey() async {
    final secureValue = await _secureStorage.read(key: privateKeyKey);
    if (secureValue != null && secureValue.trim().isNotEmpty) {
      return secureValue.trim();
    }

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

  static Future<void> deleteAllSecrets() async {
    await deletePrivateKey();
    await deleteHiveAesKey();
  }
}
