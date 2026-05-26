import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:dart_nostr/dart_nostr.dart';

import '../models/contact_model.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';

/// Rezultatul unui backup decriptat cu succes.
class RestoredIdentityBackup {
  final String privateKey;
  final String publicKey;
  final List<ContactModel> contacts;
  final List<MessageModel> messages;
  final List<ConversationModel> conversations;

  const RestoredIdentityBackup({
    required this.privateKey,
    required this.publicKey,
    required this.contacts,
    required this.messages,
    required this.conversations,
  });
}

/// All cryptographic operations related to VaultChat identity backup/restore.
/// Fully separated from UI; testable without Flutter.
class IdentityBackupService {
  IdentityBackupService._();

  static const String backupPrefix = 'VAULTCHAT_BACKUP_V1:';
  static const int _backupIterations = 210000;

  // ── Validare ───────────────────────────────────────────────────────────────

  static bool isValidKey(String value) =>
      RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value.trim());

  static String? extractPublicKey(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    final queryKey = uri?.queryParameters['pubkey'];
    if (queryKey != null && isValidKey(queryKey)) {
      return queryKey.trim().toLowerCase();
    }
    final match = RegExp(r'[a-fA-F0-9]{64}').firstMatch(raw);
    return match?.group(0)?.toLowerCase();
  }

  static String vaultContactPayload(String publicKey) =>
      'vaultchat://contact?pubkey=${publicKey.trim().toLowerCase()}';

  static String normalizeRestorePayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith(backupPrefix)) return trimmed;
    // Supports paste with accidental whitespace or newlines
    final cleaned = trimmed.replaceAll(RegExp(r'\s+'), '');
    if (cleaned.startsWith(backupPrefix)) return cleaned;
    return trimmed;
  }

  // ── Creare backup ──────────────────────────────────────────────────────────

  static Future<String> createEncryptedBackup({
    required String privateKey,
    required String publicKey,
    required String password,
    required List<ContactModel> contacts,
    required Map<String, dynamic> storageSnapshot,
  }) async {
    if (!isValidKey(privateKey) || !isValidKey(publicKey)) {
      throw StateError('The current identity is not valid for export.');
    }

    final plaintextMap = <String, dynamic>{
      'type': 'vaultchat_identity',
      'version': 3,
      'createdAt': DateTime.now().toIso8601String(),
      'publicKey': publicKey,
      'privateKey': privateKey,
      'contacts': contacts.map((c) => c.toMap()).toList(),
      'storage': storageSnapshot,
    };

    final plaintext = utf8.encode(jsonEncode(plaintextMap));
    final salt = _secureRandomBytes(16);
    final nonce = _secureRandomBytes(12);
    final secretKey = await _deriveKey(password, salt, _backupIterations);
    final algorithm = cryptography.AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    final container = <String, dynamic>{
      'type': 'vaultchat_encrypted_identity_backup',
      'version': 2,
      'algorithm': 'aes-256-gcm',
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': _backupIterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(secretBox.nonce),
      'cipher': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
      'createdAt': DateTime.now().toIso8601String(),
      'publicKeyHint': publicKey.substring(0, 8),
    };

    return '$backupPrefix${base64Encode(utf8.encode(jsonEncode(container)))}';
  }

  // ── Decriptare backup ──────────────────────────────────────────────────────

  static Future<RestoredIdentityBackup> decryptBackup(
    String backupText,
    String password,
  ) async {
    final normalized = normalizeRestorePayload(backupText);

    // Simple case: raw private key hex (without backup wrapper)
    if (isValidKey(normalized)) {
      final nostr = Nostr.instance;
      final pair = nostr.keys.generateKeyPairFromExistingPrivateKey(normalized.trim());
      return RestoredIdentityBackup(
        privateKey: normalized.trim(),
        publicKey: pair.public,
        contacts: const [],
        messages: const [],
        conversations: const [],
      );
    }

    if (!normalized.startsWith(backupPrefix)) {
      throw const FormatException('Invalid backup format.');
    }

    final encoded = normalized.substring(backupPrefix.length).trim();
    final containerText = utf8.decode(base64Decode(encoded));
    final container = jsonDecode(containerText);
    if (container is! Map) throw const FormatException('Container invalid.');

    final version = (container['version'] as num?)?.toInt();
    if (version == 2) return _decryptV2(container, password);
    if (version == 1) return _decryptV1Legacy(container, password);

    throw const FormatException('Unsupported backup version.');
  }

  // ── V2 (AES-GCM via cryptography package) ─────────────────────────────────

  static Future<RestoredIdentityBackup> _decryptV2(
    Map container,
    String password,
  ) async {
    final iterations =
        (container['iterations'] as num?)?.toInt() ?? _backupIterations;
    final salt = base64Decode(container['salt'] as String);
    final nonce = base64Decode(container['nonce'] as String);
    final cipherBytes = base64Decode(container['cipher'] as String);
    final macBytes = base64Decode(container['mac'] as String);

    final secretKey = await _deriveKey(password, salt, iterations);
    final algorithm = cryptography.AesGcm.with256bits();
    final plainBytes = await algorithm.decrypt(
      cryptography.SecretBox(cipherBytes, nonce: nonce, mac: cryptography.Mac(macBytes)),
      secretKey: secretKey,
    );

    return _parsePlaintext(plainBytes);
  }

  // ── V1 Legacy (PBKDF2 + XOR-CTR + HMAC-SHA256) ────────────────────────────

  static RestoredIdentityBackup _decryptV1Legacy(Map container, String password) {
    final iterations =
        (container['iterations'] as num?)?.toInt() ?? _backupIterations;
    final salt = base64Decode(container['salt'] as String);
    final nonce = base64Decode(container['nonce'] as String);
    final cipherBytes = base64Decode(container['cipher'] as String);
    final expectedMac = base64Decode(container['mac'] as String);

    final key = _deriveLegacyKey(password, salt, iterations);
    final actualMac = _legacyMac(key, nonce, cipherBytes);
    if (!_constantTimeEquals(expectedMac, actualMac)) {
      throw const FormatException('MAC invalid.');
    }

    final plainBytes = _xorKeyStream(cipherBytes, key, nonce);
    return _parsePlaintext(plainBytes);
  }

  // ── Parser plaintext comun ─────────────────────────────────────────────────

  static RestoredIdentityBackup _parsePlaintext(List<int> plainBytes) {
    final plain = jsonDecode(utf8.decode(plainBytes));
    if (plain is! Map) throw const FormatException('Plaintext invalid.');

    final privateKey = (plain['privateKey'] ?? '').toString().trim();
    final publicKey = (plain['publicKey'] ?? '').toString().trim().toLowerCase();
    if (!isValidKey(privateKey) || !isValidKey(publicKey)) {
      throw const FormatException('Invalid keys in backup.');
    }

    final contacts = <ContactModel>[];
    final contactsRaw = plain['contacts'];
    if (contactsRaw is List) {
      for (final item in contactsRaw) {
        if (item is Map) {
          final c = ContactModel.fromMap(item);
          if (c.publicKey.trim().isNotEmpty && c.displayName.trim().isNotEmpty) {
            contacts.add(c);
          }
        }
      }
    }

    final messages = <MessageModel>[];
    final conversations = <ConversationModel>[];
    final storageRaw = plain['storage'];
    if (storageRaw is Map) {
      final msgRaw = storageRaw['messages'];
      if (msgRaw is List) {
        for (final item in msgRaw) {
          if (item is Map) {
            final m = MessageModel.fromMap(item);
            if (m.id.trim().isNotEmpty &&
                m.senderPublicKey.trim().isNotEmpty &&
                m.recipientPublicKey.trim().isNotEmpty) {
              messages.add(m);
            }
          }
        }
      }
      final convRaw = storageRaw['conversations'];
      if (convRaw is List) {
        for (final item in convRaw) {
          if (item is Map) {
            final c = ConversationModel.fromMap(item);
            if (c.id.trim().isNotEmpty &&
                c.myPublicKey.trim().isNotEmpty &&
                c.peerPublicKey.trim().isNotEmpty) {
              conversations.add(c);
            }
          }
        }
      }
    }

    return RestoredIdentityBackup(
      privateKey: privateKey,
      publicKey: publicKey,
      contacts: contacts,
      messages: messages,
      conversations: conversations,
    );
  }

  // ── Crypto helpers ─────────────────────────────────────────────────────────

  static Future<cryptography.SecretKey> _deriveKey(
    String password,
    List<int> salt,
    int iterations,
  ) {
    return cryptography.Pbkdf2(
      macAlgorithm: cryptography.Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static List<int> _deriveLegacyKey(String password, List<int> salt, int iterations) {
    final passwordBytes = utf8.encode(password);
    final hmac = Hmac(sha256, passwordBytes);
    final blockIndex = <int>[0, 0, 0, 1];
    var u = hmac.convert([...salt, ...blockIndex]).bytes;
    final output = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < output.length; j++) {
        output[j] ^= u[j];
      }
    }
    return output;
  }

  static List<int> _xorKeyStream(List<int> input, List<int> key, List<int> nonce) {
    final output = <int>[];
    var counter = 0;
    while (output.length < input.length) {
      final counterBytes = [
        (counter >> 24) & 0xff, (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,  counter & 0xff,
      ];
      final stream = Hmac(sha256, key).convert([...nonce, ...counterBytes]).bytes;
      for (final byte in stream) {
        if (output.length >= input.length) break;
        output.add(input[output.length] ^ byte);
      }
      counter++;
    }
    return output;
  }

  static List<int> _legacyMac(List<int> key, List<int> nonce, List<int> cipher) =>
      Hmac(sha256, key).convert([...utf8.encode('vaultchat-backup-v1'), ...nonce, ...cipher]).bytes;

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
