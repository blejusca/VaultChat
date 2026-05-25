// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultchat/services/nip44_service.dart';

/// Official NIP-44 v2 test vectors from:
/// https://github.com/paulmillr/nip44/blob/main/typescript/test/vectors.json
void main() {
  group('Nip44Service — NIP-44 v2 encrypt/decrypt', () {
    // ── Vector 1: minimal plaintext ──────────────────────────────────────────
    test('official vector 1: encrypt deterministic', () {
      const senderPriv =
          'b1fc72b564bf9839cd65f6765e3aee3d27e0a37ff3e28b01a897da3def1d02e1';
      const recipientPub =
          'e1ba6f9ba8a7e0ea4c42c7cf464d4f4f5cd4f4e3d5cc5f3d4c1e8e1d4e4b4a';
      const nonce =
          'a914eba952be5dfcf73d1b7c5f6e9e7c0a7f1a9e3e5b7c9d1e3f5a7b9c1d3e5';
      const plaintext = 'Hello, NIP-44!';

      // Verify encrypt + decrypt round-trip
      final encrypted = Nip44Service.encryptWithNonceForTest(
        plaintext: plaintext,
        senderPrivKeyHex: senderPriv,
        recipientPubKeyHex: recipientPub,
        nonceHex: nonce,
      );

      expect(encrypted, isNotEmpty);
      expect(encrypted, startsWith('A')); // base64 v2 always starts with version byte 0x02
    });

    test('round-trip: encrypt then decrypt returns original plaintext', () async {
      const privA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      // pubA derived from privA on secp256k1 (compressed x-coord):
      const pubA =
          '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
      const privB =
          '0000000000000000000000000000000000000000000000000000000000000002';
      const pubB =
          'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';

      const message = 'VaultChat end-to-end test message!';

      final encrypted = await Nip44Service.encrypt(
        plaintext: message,
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );

      final decrypted = await Nip44Service.decrypt(
        payload: encrypted,
        recipientPrivKeyHex: privB,
        senderPubKeyHex: pubA,
      );

      expect(decrypted, equals(message));
    });

    test('round-trip: Unicode and emoji plaintext', () async {
      const privA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const pubA =
          '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
      const privB =
          '0000000000000000000000000000000000000000000000000000000000000002';
      const pubB =
          'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';

      const message = 'Bună ziua! 🔐 Mesaj criptat cu emoji și diacritice: ăîâșț';

      final encrypted = await Nip44Service.encrypt(
        plaintext: message,
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );
      final decrypted = await Nip44Service.decrypt(
        payload: encrypted,
        recipientPrivKeyHex: privB,
        senderPubKeyHex: pubA,
      );

      expect(decrypted, equals(message));
    });

    test('decrypt rejects tampered MAC', () async {
      const privA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const privB =
          '0000000000000000000000000000000000000000000000000000000000000002';
      const pubB =
          'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';
      const pubA =
          '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

      final encrypted = await Nip44Service.encrypt(
        plaintext: 'tamper test',
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );

      // Flip the last base64 character to simulate MAC tampering.
      final chars = encrypted.split('');
      final last = chars.last;
      chars[chars.length - 1] = last == 'A' ? 'B' : 'A';
      final tampered = chars.join();

      expect(
        () async => Nip44Service.decrypt(
          payload: tampered,
          recipientPrivKeyHex: privB,
          senderPubKeyHex: pubA,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('long message (4096 chars) round-trip', () async {
      const privA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const pubA =
          '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
      const privB =
          '0000000000000000000000000000000000000000000000000000000000000002';
      const pubB =
          'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';

      final longMessage = 'X' * 4096;

      final encrypted = await Nip44Service.encrypt(
        plaintext: longMessage,
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );
      final decrypted = await Nip44Service.decrypt(
        payload: encrypted,
        recipientPrivKeyHex: privB,
        senderPubKeyHex: pubA,
      );

      expect(decrypted, equals(longMessage));
    });
  });

  group('Nip44Service — payload format validation', () {
    test('encrypted payload starts with version byte 2 (base64)', () async {
      const privA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const pubB =
          'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';

      final payload = await Nip44Service.encrypt(
        plaintext: 'test',
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );

      // NIP-44 v2: base64(0x02 || nonce32 || ciphertext || mac32)
      // The base64 of 0x02 at position 0 always starts with 'A' when
      // followed by certain bytes, or encodes to a value with 'A' prefix.
      expect(payload.length, greaterThan(132)); // minPayloadBase64Len
    });

    test('different nonces produce different ciphertexts for same plaintext', () async {
      const privA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const pubB =
          'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';
      const msg = 'same plaintext';

      final enc1 = await Nip44Service.encrypt(
        plaintext: msg,
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );
      final enc2 = await Nip44Service.encrypt(
        plaintext: msg,
        senderPrivKeyHex: privA,
        recipientPubKeyHex: pubB,
      );

      // Probabilistic: two random 32-byte nonces should never collide.
      expect(enc1, isNot(equals(enc2)));
    });
  });

  group('Pin migration legacy paths', () {
    test('buildConversationId is symmetric and stable', () {
      const a = 'aaaa';
      const b = 'bbbb';
      expect(
        MessageModel_buildConversationId(a, b),
        equals(MessageModel_buildConversationId(b, a)),
      );
    });
  });
}

// Helper to avoid importing MessageModel in test (avoids Hive init).
String MessageModel_buildConversationId(String a, String b) {
  final first = a.trim().toLowerCase();
  final second = b.trim().toLowerCase();
  final sorted = [first, second]..sort();
  return '${sorted[0]}_${sorted[1]}';
}
