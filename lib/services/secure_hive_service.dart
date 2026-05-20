import 'package:hive_flutter/hive_flutter.dart';

import 'secure_key_storage_service.dart';

class SecureHiveService {
  SecureHiveService._();

  static Future<Box> openEncryptedBox(String name) async {
    await Hive.initFlutter();
    final key = await SecureKeyStorageService.readOrCreateHiveAesKey();
    return Hive.openBox(name, encryptionCipher: HiveAesCipher(key));
  }
}
