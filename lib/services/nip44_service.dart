import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

/// NIP-44 v2 — Versioned Encrypted Payloads for Nostr.
///
/// This implementation follows the NIP-44 v2 construction:
///   1. secp256k1 ECDH -> unhashed shared X coordinate (32 bytes)
///   2. HKDF-Extract-SHA256(sharedX, salt='nip44-v2') -> conversation key
///   3. HKDF-Expand-SHA256(conversationKey, info=nonce32, L=76) -> message keys
///      - bytes 0..32  = ChaCha20 key
///      - bytes 32..44 = ChaCha20 nonce
///      - bytes 44..76 = HMAC-SHA256 key
///   4. NIP-44 padding
///   5. ChaCha20 encryption, RFC8439 96-bit nonce, counter 0
///   6. HMAC-SHA256 over nonce32 || ciphertext
///   7. base64(version[1] || nonce32 || ciphertext || mac32)
class Nip44Service {
  Nip44Service._();

  static const int _version = 2;
  static const int _nonceLen = 32;
  static const int _chachaNonceLen = 12;
  static const int _macLen = 32;
  static const int _conversationKeyLen = 32;
  static const int _messageKeysLen = 76;
  static const int _minPlaintextLen = 1;
  static const int _maxPlaintextLen = 65535;
  static const int _minPayloadBase64Len = 132;
  static const int _maxPayloadBase64Len = 87472;
  static const int _minPayloadBytesLen = 99;
  static const int _maxPayloadBytesLen = 65603;
  static const String _hkdfExtractSalt = 'nip44-v2';

  // secp256k1 order.
  static final BigInt _curveOrder = BigInt.parse(
    'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
    radix: 16,
  );

  /// Encrypt [plaintext] from [senderPrivKeyHex] to [recipientPubKeyHex].
  /// Returns a NIP-44 v2 base64 payload suitable as Nostr event content.
  static Future<String> encrypt({
    required String plaintext,
    required String senderPrivKeyHex,
    required String recipientPubKeyHex,
  }) async {
    final nonce = _secureRandom(_nonceLen);
    final conversationKey = _conversationKey(senderPrivKeyHex, recipientPubKeyHex);
    return _encryptWithConversationKey(
      plaintext: plaintext,
      conversationKey: conversationKey,
      nonce: nonce,
    );
  }

  /// Decrypt a NIP-44 v2 [payload] (base64).
  /// Throws [ArgumentError] on invalid format, unsupported version,
  /// invalid MAC or invalid padding.
  static Future<String> decrypt({
    required String payload,
    required String recipientPrivKeyHex,
    required String senderPubKeyHex,
  }) async {
    final conversationKey = _conversationKey(recipientPrivKeyHex, senderPubKeyHex);
    return _decryptWithConversationKey(
      payload: payload,
      conversationKey: conversationKey,
    );
  }

  /// Exposed for deterministic local tests against official NIP-44 vectors.
  /// Do not call from production messaging code.
  @visibleForTesting
  static String encryptWithNonceForTest({
    required String plaintext,
    required String senderPrivKeyHex,
    required String recipientPubKeyHex,
    required String nonceHex,
  }) {
    final nonce = _hexToBytes(nonceHex);
    if (nonce.length != _nonceLen) {
      throw ArgumentError('NIP-44: nonce invalid pentru test');
    }
    final conversationKey = _conversationKey(senderPrivKeyHex, recipientPubKeyHex);
    return _encryptWithConversationKey(
      plaintext: plaintext,
      conversationKey: conversationKey,
      nonce: nonce,
    );
  }

  // ── NIP-44 core ───────────────────────────────────────────────────────────

  static String _encryptWithConversationKey({
    required String plaintext,
    required Uint8List conversationKey,
    required Uint8List nonce,
  }) {
    if (nonce.length != _nonceLen) {
      throw ArgumentError('NIP-44: nonce invalid');
    }

    final messageKeys = _messageKeys(conversationKey, nonce);
    final padded = _pad(utf8.encode(plaintext));
    final cipherText = _chacha20(
      key: messageKeys.chachaKey,
      nonce: messageKeys.chachaNonce,
      input: padded,
    );
    final mac = _hmacAad(
      key: messageKeys.hmacKey,
      aad: nonce,
      message: cipherText,
    );

    final wire = Uint8List(1 + _nonceLen + cipherText.length + _macLen);
    var offset = 0;
    wire[offset++] = _version;
    wire.setAll(offset, nonce);
    offset += _nonceLen;
    wire.setAll(offset, cipherText);
    offset += cipherText.length;
    wire.setAll(offset, mac);

    return base64.encode(wire);
  }

  static String _decryptWithConversationKey({
    required String payload,
    required Uint8List conversationKey,
  }) {
    final decoded = _decodePayload(payload);
    final messageKeys = _messageKeys(conversationKey, decoded.nonce);
    final expectedMac = _hmacAad(
      key: messageKeys.hmacKey,
      aad: decoded.nonce,
      message: decoded.cipherText,
    );

    if (!_constantTimeEquals(expectedMac, decoded.mac)) {
      throw ArgumentError('NIP-44: MAC invalid');
    }

    final paddedPlaintext = _chacha20(
      key: messageKeys.chachaKey,
      nonce: messageKeys.chachaNonce,
      input: decoded.cipherText,
    );
    return utf8.decode(_unpad(paddedPlaintext));
  }

  static _DecodedPayload _decodePayload(String payload) {
    final clean = payload.trim();
    if (clean.isEmpty || clean.startsWith('#')) {
      throw ArgumentError('NIP-44: unsupported version/encoding');
    }
    if (clean.length < _minPayloadBase64Len ||
        clean.length > _maxPayloadBase64Len) {
      throw ArgumentError('NIP-44: dimensiune payload base64 invalida');
    }

    late Uint8List wire;
    try {
      wire = Uint8List.fromList(base64.decode(clean));
    } catch (_) {
      throw ArgumentError('NIP-44: base64 invalid');
    }

    if (wire.length < _minPayloadBytesLen ||
        wire.length > _maxPayloadBytesLen) {
      throw ArgumentError('NIP-44: invalid decoded payload size');
    }
    if (wire[0] != _version) {
      throw ArgumentError('NIP-44: versiune necunoscuta: ${wire[0]}');
    }

    final nonce = wire.sublist(1, 1 + _nonceLen);
    final cipherText = wire.sublist(1 + _nonceLen, wire.length - _macLen);
    final mac = wire.sublist(wire.length - _macLen);

    return _DecodedPayload(nonce: nonce, cipherText: cipherText, mac: mac);
  }

  // ── ECDH / secp256k1 ─────────────────────────────────────────────────────

  static Uint8List _conversationKey(String privKeyHex, String pubKeyHex) {
    final sharedX = _ecdhSharedX(privKeyHex, pubKeyHex);
    return _hkdfExtract(
      salt: Uint8List.fromList(utf8.encode(_hkdfExtractSalt)),
      ikm: sharedX,
    );
  }

  static Uint8List _ecdhSharedX(String privKeyHex, String pubKeyHex) {
    final domainParams = ECDomainParameters('secp256k1');

    final privateKey = _normalizeHex(privKeyHex, expectedLength: 64);
    final privateScalar = BigInt.parse(privateKey, radix: 16);
    if (privateScalar <= BigInt.zero || privateScalar >= _curveOrder) {
      throw ArgumentError('NIP-44: invalid private key');
    }

    // Nostr public keys are BIP-340 x-only. Decoding with prefix 02 selects the
    // even-Y point. Multiplying the odd-Y counterpart would produce the same X
    // coordinate, so the ECDH shared X is stable for x-only keys.
    final publicKey = _normalizeHex(pubKeyHex, expectedLength: 64);
    final pubPoint = domainParams.curve.decodePoint(_hexToBytes('02$publicKey'));
    if (pubPoint == null || pubPoint.isInfinity) {
      throw ArgumentError('NIP-44: invalid public key');
    }

    final sharedPoint = pubPoint * privateScalar;
    if (sharedPoint == null || sharedPoint.isInfinity) {
      throw ArgumentError('NIP-44: ECDH failed');
    }

    final x = sharedPoint.x?.toBigInteger();
    if (x == null) throw ArgumentError('NIP-44: ECDH fara coordonata X');
    return _bigIntToBytes(x, 32);
  }

  // ── HKDF-SHA256 ──────────────────────────────────────────────────────────

  static Uint8List _hkdfExtract({
    required Uint8List salt,
    required Uint8List ikm,
  }) {
    return Uint8List.fromList(crypto.Hmac(crypto.sha256, salt).convert(ikm).bytes);
  }

  static Uint8List _hkdfExpand({
    required Uint8List prk,
    required Uint8List info,
    required int length,
  }) {
    if (prk.length != _conversationKeyLen) {
      throw ArgumentError('NIP-44: conversation_key invalid');
    }
    if (length <= 0 || length > 255 * 32) {
      throw ArgumentError('NIP-44: lungime HKDF invalida');
    }

    final output = BytesBuilder(copy: false);
    var previous = Uint8List(0);
    var counter = 1;

    while (output.length < length) {
      final input = BytesBuilder(copy: false)
        ..add(previous)
        ..add(info)
        ..add([counter]);
      previous = Uint8List.fromList(
        crypto.Hmac(crypto.sha256, prk).convert(input.takeBytes()).bytes,
      );
      output.add(previous);
      counter += 1;
    }

    return Uint8List.fromList(output.takeBytes().sublist(0, length));
  }

  static _MessageKeys _messageKeys(Uint8List conversationKey, Uint8List nonce) {
    if (conversationKey.length != _conversationKeyLen) {
      throw ArgumentError('NIP-44: conversation_key invalid');
    }
    if (nonce.length != _nonceLen) {
      throw ArgumentError('NIP-44: nonce invalid');
    }

    final keys = _hkdfExpand(
      prk: conversationKey,
      info: nonce,
      length: _messageKeysLen,
    );

    return _MessageKeys(
      chachaKey: keys.sublist(0, 32),
      chachaNonce: keys.sublist(32, 32 + _chachaNonceLen),
      hmacKey: keys.sublist(44, 76),
    );
  }

  // ── ChaCha20 + HMAC ──────────────────────────────────────────────────────

  static Uint8List _chacha20({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List input,
  }) {
    if (key.length != 32) throw ArgumentError('NIP-44: ChaCha key invalid');
    if (nonce.length != _chachaNonceLen) {
      throw ArgumentError('NIP-44: ChaCha nonce invalid');
    }

    final engine = ChaCha7539Engine();
    engine.init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), nonce));
    final out = Uint8List(input.length);
    engine.processBytes(input, 0, input.length, out, 0);
    return out;
  }

  static Uint8List _hmacAad({
    required Uint8List key,
    required Uint8List aad,
    required Uint8List message,
  }) {
    if (aad.length != _nonceLen) {
      throw ArgumentError('NIP-44: AAD invalid');
    }
    final data = BytesBuilder(copy: false)
      ..add(aad)
      ..add(message);
    return Uint8List.fromList(
      crypto.Hmac(crypto.sha256, key).convert(data.takeBytes()).bytes,
    );
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ── Padding ──────────────────────────────────────────────────────────────

  static Uint8List _pad(List<int> plain) {
    final len = plain.length;
    if (len < _minPlaintextLen || len > _maxPlaintextLen) {
      throw ArgumentError('NIP-44: lungime plaintext invalida');
    }

    final paddedLen = _calcPaddedLen(len);
    final padded = Uint8List(2 + paddedLen);
    padded[0] = (len >> 8) & 0xff;
    padded[1] = len & 0xff;
    padded.setAll(2, plain);
    return padded;
  }

  static Uint8List _unpad(Uint8List padded) {
    if (padded.length < 2) throw ArgumentError('NIP-44: padding invalid');
    final len = (padded[0] << 8) | padded[1];
    if (len < _minPlaintextLen || len > _maxPlaintextLen) {
      throw ArgumentError('NIP-44: lungime plaintext invalida');
    }
    if (padded.length != 2 + _calcPaddedLen(len)) {
      throw ArgumentError('NIP-44: dimensiune padding invalida');
    }
    if (2 + len > padded.length) {
      throw ArgumentError('NIP-44: lungime padding invalida');
    }
    return padded.sublist(2, 2 + len);
  }

  static int _calcPaddedLen(int unpaddedLen) {
    if (unpaddedLen <= 0 || unpaddedLen > _maxPlaintextLen) {
      throw ArgumentError('NIP-44: lungime padding invalida');
    }
    if (unpaddedLen <= 32) return 32;

    final nextPower = 1 << (_floorLog2(unpaddedLen - 1) + 1);
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * (((unpaddedLen - 1) ~/ chunk) + 1);
  }

  static int _floorLog2(int value) {
    if (value <= 0) return 0;
    var result = 0;
    var v = value;
    while (v > 1) {
      v >>= 1;
      result += 1;
    }
    return result;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static Uint8List _secureRandom(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => rng.nextInt(256)));
  }

  static String _normalizeHex(String value, {required int expectedLength}) {
    final clean = value.trim().toLowerCase();
    if (clean.length != expectedLength || !RegExp(r'^[0-9a-f]+$').hasMatch(clean)) {
      throw ArgumentError('NIP-44: invalid hex key');
    }
    return clean;
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.trim().toLowerCase();
    if (clean.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(clean)) {
      throw ArgumentError('NIP-44: hex invalid');
    }
    final result = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    return _hexToBytes(hex);
  }
}

class _MessageKeys {
  final Uint8List chachaKey;
  final Uint8List chachaNonce;
  final Uint8List hmacKey;

  const _MessageKeys({
    required this.chachaKey,
    required this.chachaNonce,
    required this.hmacKey,
  });
}

class _DecodedPayload {
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  const _DecodedPayload({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });
}
