import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as crypto_graphy;
import 'package:pointycastle/export.dart';

enum AttachmentType { image, pdf, unknown }

AttachmentType attachmentTypeFromMime(String mime) {
  if (mime.startsWith('image/')) return AttachmentType.image;
  if (mime == 'application/pdf') return AttachmentType.pdf;
  return AttachmentType.unknown;
}

class AttachmentMeta {
  final String url;
  final String encKey;
  final String encIv;
  final String encTag;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final String blobSha256;

  const AttachmentMeta({
    required this.url,
    required this.encKey,
    required this.encIv,
    required this.encTag,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    this.blobSha256 = '',
  });

  AttachmentType get type => attachmentTypeFromMime(mimeType);

  Map<String, dynamic> toJson() => {
        'vault_attachment': true,
        'url': url,
        'enc_key': encKey,
        'enc_iv': encIv,
        'enc_tag': encTag,
        'file_name': fileName,
        'mime_type': mimeType,
        'file_size': fileSize,
        if (blobSha256.isNotEmpty) 'blob_sha256': blobSha256,
      };

  static AttachmentMeta? tryFromJson(Map<String, dynamic> json) {
    try {
      if (json['vault_attachment'] != true) return null;
      final sizeValue = json['file_size'];
      return AttachmentMeta(
        url: (json['url'] ?? '').toString(),
        encKey: (json['enc_key'] ?? '').toString(),
        encIv: (json['enc_iv'] ?? '').toString(),
        encTag: (json['enc_tag'] ?? '').toString(),
        fileName: (json['file_name'] ?? 'attachment').toString(),
        mimeType: (json['mime_type'] ?? 'application/octet-stream').toString(),
        fileSize: sizeValue is int
            ? sizeValue
            : sizeValue is num
                ? sizeValue.toInt()
                : int.tryParse('$sizeValue') ?? 0,
        blobSha256: (json['blob_sha256'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static AttachmentMeta? tryFromMessageText(String text) {
    try {
      if (!text.contains('"vault_attachment"')) return null;
      final json = jsonDecode(text) as Map<String, dynamic>;
      return tryFromJson(json);
    } catch (_) {
      return null;
    }
  }
}

class UploadResult {
  final String remoteUrl;
  final String encKeyHex;
  final String encIvHex;
  final String encTagHex;
  final String blobSha256;

  const UploadResult({
    required this.remoteUrl,
    required this.encKeyHex,
    required this.encIvHex,
    required this.encTagHex,
    required this.blobSha256,
  });
}

class FileTransferService {
  FileTransferService._();

  static const int maxFileSizeBytes = 25 * 1024 * 1024; // limita tehnica de siguranta: fisiere <= 25 MB
  static const Duration _uploadTimeout = Duration(seconds: 45);
  static const Duration _requestSendTimeout = Duration(seconds: 45);
  static const Duration _requestReadTimeout = Duration(seconds: 45);

  // Fallback inline: doar pentru fisiere foarte mici. Nu este solutia finala,
  // dar evita blocarea totala daca toate serviciile publice de upload refuza.
  static const int _maxInlineEncryptedBytes = 4 * 1024; // doar fallback de diagnostic; NU trimitem fisiere prin Nostr

  // ── AVERTISMENT DE SECURITATE ─────────────────────────────────────────────
  // Serverele de mai jos sunt servicii TERȚE PUBLICE necontrolate.
  // Conținutul fișierelor este criptat AES-GCM-256 înainte de upload, deci
  // operatorii NU pot citi datele. Cu toate acestea:
  //   - Metadatele (dimensiune, timing, frecvență) sunt vizibile.
  //   - Disponibilitatea nu este garantată (servicii gratuite cu TTL variabil).
  //   - RECOMANDAT pentru producție: înlocuiți cu infrastructură proprie
  //     (MinIO, AWS S3 privat, sau Nostr Blossom BUD-06).
  // ─────────────────────────────────────────────────────────────────────────
  // Servere externe pentru stocarea fișierului criptat.
  // Ordinea evită Litterbox/Catbox ca primă opțiune, deoarece pe unele telefoane
  // Android request-ul multipart către ele poate rămâne suspendat mult timp.
  static const List<_UploadServer> _servers = [
    // tmpfiles.org a dat 404 la download in teste; îl păstrăm implementat,
    // dar nu îl folosim implicit pentru atașamente criptate.
    _UploadServer.pomf,
    _UploadServer.catbox,
    _UploadServer.litterbox,
    _UploadServer.voidCat,
  ];

  static Future<UploadResult> encryptAndUpload({
    required Uint8List fileBytes,
    required String fileName,
    required String mimeType,
    void Function(String message)? onProgress,
  }) async {
    if (fileBytes.length > maxFileSizeBytes) {
      throw Exception('The file exceeds the current 25 MB limit.');
    }

    final key = _secureRandom(32);
    final iv = _secureRandom(12);

    // AES-GCM stabilizat: folosim pachetul cryptography pentru fișiere.
    // PointyCastle rămâne mai jos doar pentru compatibilitate cu mesaje vechi.
    final encrypted = await _encryptAesGcmStable(
      plaintext: fileBytes,
      key: key,
      iv: iv,
    );

    onProgress?.call('Encrypting file...');

    // Blob v2: ciphertext + tag. Tag-ul este inclus în fișierul uploadat.
    final uploadBlob = Uint8List(encrypted.ciphertext.length + encrypted.tag.length)
      ..setAll(0, encrypted.ciphertext)
      ..setAll(encrypted.ciphertext.length, encrypted.tag);
    final blobSha256 = _sha256Hex(uploadBlob);

    String? uploadedUrl;
    final List<String> errors = [];

    // Regula fixa: NU trimitem continutul fisierului prin Nostr.
    // Nostr primeste doar metadata mica + URL. Continutul criptat merge pe storage extern.
    for (final server in _servers) {
      try {
        onProgress?.call('Uploading file...');
        final candidateUrl = await _runWithTimeout<String>(
          server.upload(
            encryptedBytes: uploadBlob,
            fileName: '${_randomHex(8)}.bin',
          ),
          _uploadTimeout,
          'Timeout upload ${server.name}',
        );

        // Stabilizare critică: nu trimitem URL-ul mai departe până nu verifyingm
        // că serverul returnează EXACT același blob criptat. Asta previne
        // InvalidCipherTextException și HTTP 404 la destinatar.
        onProgress?.call('Verifying secure transfer...');
        final downloaded = await _downloadWithRedirect(candidateUrl);
        if (!_bytesEqual(downloaded, uploadBlob)) {
          throw Exception(
            'Verification failed: downloaded bytes differ '
            '(${downloaded.length} vs ${uploadBlob.length}).',
          );
        }

        uploadedUrl = candidateUrl;
        onProgress?.call('File verified. Sending message...');
        break;
      } catch (e) {
        errors.add('${server.name}: $e');
        onProgress?.call('Server unavailable. Trying another server automatically...');
      }
    }

    uploadedUrl ??= _buildInlineUrlIfSmall(uploadBlob, errors);

    // enc_tag este acum redundant (inclus în blob) dar îl păstrăm pentru compatibilitate.
    return UploadResult(
      remoteUrl: uploadedUrl,
      encKeyHex: _toHex(key),
      encIvHex: _toHex(iv),
      encTagHex: _toHex(encrypted.tag),
      blobSha256: blobSha256,
    );
  }

  static Future<Uint8List> downloadAndDecrypt({
    required String url,
    required String encKeyHex,
    required String encIvHex,
    required String encTagHex,
    String blobSha256 = '',
  }) async {
    final Uint8List encryptedBytes;

    if (url.startsWith('inline://')) {
      encryptedBytes = base64Decode(url.substring('inline://'.length));
    } else {
      encryptedBytes = await _downloadWithRedirect(url);
    }

    if (blobSha256.isNotEmpty) {
      final actualHash = _sha256Hex(encryptedBytes);
      if (actualHash != blobSha256) {
        throw Exception(
          'File corrupted after download: hash mismatch. '
          'Expected $blobSha256, received $actualHash. Resend the file.',
        );
      }
    }

    // Blob v2: tag-ul este inclus în ultimii 16 bytes ai fișierului.
    if (encryptedBytes.length < 17) {
      throw Exception('Downloaded blob too small: ${encryptedBytes.length} bytes');
    }
    final ciphertext = encryptedBytes.sublist(0, encryptedBytes.length - 16);
    final tagFromBlob = encryptedBytes.sublist(encryptedBytes.length - 16);
    final key = _fromHex(encKeyHex);
    final iv = _fromHex(encIvHex);

    try {
      return await _decryptAesGcmStable(
        ciphertext: ciphertext,
        key: key,
        iv: iv,
        tag: tagFromBlob,
      );
    } catch (_) {
      // Compatibilitate defensivă cu mesaje generate de versiuni intermediare:
      // dacă tag-ul inclus în blob nu merge, încercăm tag-ul din metadata.
      if (encTagHex.trim().isNotEmpty) {
        return _decryptAesGcm(_DecryptParams(
          ciphertext: ciphertext,
          key: key,
          iv: iv,
          tag: _fromHex(encTagHex),
        ));
      }
      rethrow;
    }
  }

  /// Descarcă bytes urmărind redirect-uri manual (301/302/307/308).
  /// Flutter http package nu urmărește automat redirect-urile pe GET în toate cazurile.
  static Future<Uint8List> _downloadWithRedirect(String url, {int maxRedirects = 6}) async {
    var currentUrl = url;
    for (var i = 0; i < maxRedirects; i++) {
      final response = await http.get(
        Uri.parse(currentUrl),
        headers: const {'User-Agent': 'VaultChat/1.0'},
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        if (response.bodyBytes.isEmpty) {
          throw Exception('Empty response from server: $currentUrl');
        }
        // Verifică că nu e HTML (pagină de eroare în loc de fișier binar)
        final contentType = response.headers['content-type'] ?? '';
        if (contentType.contains('text/html')) {
          throw Exception(
            'The server returned HTML instead of a binary file. '
            'URL posibil expirat sau invalid: $currentUrl'
          );
        }
        return response.bodyBytes;
      }

      if (response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 307 ||
          response.statusCode == 308) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw Exception('Redirect without Location header (${response.statusCode})');
        }
        currentUrl = location.startsWith('http')
            ? location
            : Uri.parse(currentUrl).resolve(location).toString();
        continue;
      }

      throw Exception('HTTP ${response.statusCode} la $currentUrl');
    }
    throw Exception('Prea multe redirect-uri pentru $url');
  }

  static Future<T> _runWithTimeout<T>(
    Future<T> future,
    Duration duration,
    String timeoutMessage,
  ) {
    return future.timeout(duration, onTimeout: () {
      throw TimeoutException(timeoutMessage, duration);
    });
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _sha256Hex(Uint8List bytes) => crypto.sha256.convert(bytes).toString();


  static String _buildInlineUrlIfSmall(Uint8List encryptedBytes, List<String> errors) {
    if (encryptedBytes.length <= _maxInlineEncryptedBytes) {
      return 'inline://${base64Encode(encryptedBytes)}';
    }

    throw Exception(
      'Could not upload the file to the available servers.\n\n'
      'The encrypted file is too large for local fallback sending '
      '(${encryptedBytes.length} bytes).\n\n'
      'Detalii:\n${errors.join('\n')}',
    );
  }

  static Uint8List _secureRandom(int length) {
    final rng = FortunaRandom();
    final seed = Random.secure();
    rng.seed(KeyParameter(
      Uint8List.fromList(List<int>.generate(32, (_) => seed.nextInt(256))),
    ));
    return rng.nextBytes(length);
  }

  static String _toHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final r = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < r.length; i++) {
      r[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return r;
  }

  static String _randomHex(int bytes) => _toHex(_secureRandom(bytes));
}

enum _UploadServer {
  litterbox,
  tmpFiles,
  pomf,
  catbox,
  voidCat;

  String get name {
    switch (this) {
      case _UploadServer.litterbox:
        return 'litterbox.catbox.moe';
      case _UploadServer.tmpFiles:
        return 'tmpfiles.org';
      case _UploadServer.pomf:
        return 'pomf.cat';
      case _UploadServer.catbox:
        return 'catbox.moe';
      case _UploadServer.voidCat:
        return 'void.cat';
    }
  }

  Future<String> upload({
    required Uint8List encryptedBytes,
    required String fileName,
  }) async {
    switch (this) {
      case _UploadServer.litterbox:
        return _uploadLitterbox(encryptedBytes, fileName);
      case _UploadServer.tmpFiles:
        return _uploadTmpFiles(encryptedBytes, fileName);
      case _UploadServer.pomf:
        return _uploadPomf(encryptedBytes, fileName);
      case _UploadServer.catbox:
        return _uploadCatbox(encryptedBytes, fileName);
      case _UploadServer.voidCat:
        return _uploadVoidCat(encryptedBytes, fileName);
    }
  }

  static http.MultipartFile _binPart(String field, Uint8List bytes, String fileName) {
    return http.MultipartFile.fromBytes(
      field,
      bytes,
      filename: fileName,
      contentType: MediaType('application', 'octet-stream'),
    );
  }

  static Future<String> _sendMultipartAndRead(
    http.MultipartRequest request,
  ) async {
    request.headers['User-Agent'] = 'VaultChat/1.0';
    request.headers['Accept'] = '*/*';

    final streamed = await request.send().timeout(FileTransferService._requestSendTimeout);
    final body = await streamed.stream
        .bytesToString()
        .timeout(FileTransferService._requestReadTimeout);

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Status ${streamed.statusCode}: $body');
    }

    return body.trim();
  }


  static Future<String> _uploadLitterbox(Uint8List bytes, String fileName) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://litterbox.catbox.moe/resources/internals/api.php'),
    );
    request.fields['reqtype'] = 'fileupload';
    request.fields['time'] = '1h';
    request.files.add(_binPart('fileToUpload', bytes, fileName));

    final body = await _sendMultipartAndRead(request);
    if (body.startsWith('https://')) return body;
    throw Exception('Raspuns neasteptat: $body');
  }

  static Future<String> _uploadPomf(Uint8List bytes, String fileName) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://pomf.cat/upload.php'),
    );
    request.files.add(_binPart('files[]', bytes, fileName));

    final body = await _sendMultipartAndRead(request);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final files = json['files'] as List?;
    if (files != null && files.isNotEmpty) {
      final first = files.first as Map<String, dynamic>;
      final url = first['url']?.toString();
      if (url != null && url.isNotEmpty) {
        return url.startsWith('http') ? url : 'https://a.pomf.cat/$url';
      }
    }

    throw Exception('Could not extract URL. Body: $body');
  }

  static Future<String> _uploadCatbox(Uint8List bytes, String fileName) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://catbox.moe/user/api.php'),
    );
    request.fields['reqtype'] = 'fileupload';
    request.files.add(_binPart('fileToUpload', bytes, fileName));

    final body = await _sendMultipartAndRead(request);
    if (body.startsWith('https://')) return body;
    throw Exception('Unexpected response: $body');
  }

  static Future<String> _uploadTmpFiles(Uint8List bytes, String fileName) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://tmpfiles.org/api/v1/upload'),
    );
    request.files.add(_binPart('file', bytes, fileName));

    final body = await _sendMultipartAndRead(request);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>?;
    final url = data?['url']?.toString();
    if (url != null && url.startsWith('http')) {
      // URL-ul API este de forma /123/file.bin; pentru download direct trebuie /dl/123/file.bin.
      return url.replaceFirst('tmpfiles.org/', 'tmpfiles.org/dl/');
    }
    throw Exception('Could not extract URL. Body: $body');
  }

  static Future<String> _uploadVoidCat(Uint8List bytes, String fileName) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://void.cat/upload'),
    );
    request.headers['V-Full-Digest'] = 'true';
    request.files.add(_binPart('file', bytes, fileName));

    final body = await _sendMultipartAndRead(request);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final fileObj = json['file'] as Map<String, dynamic>?;
    final url = fileObj?['url']?.toString() ?? json['url']?.toString();
    if (url != null && url.isNotEmpty) return url;

    final id = fileObj?['id']?.toString() ?? json['id']?.toString();
    if (id != null && id.isNotEmpty) return 'https://void.cat/d/$id';

    throw Exception('Could not extract URL. Body: $body');
  }
}


Future<_EncryptResult> _encryptAesGcmStable({
  required Uint8List plaintext,
  required Uint8List key,
  required Uint8List iv,
}) async {
  final algorithm = crypto_graphy.AesGcm.with256bits();
  final secretBox = await algorithm.encrypt(
    plaintext,
    secretKey: crypto_graphy.SecretKey(key),
    nonce: iv,
  );
  return _EncryptResult(
    ciphertext: Uint8List.fromList(secretBox.cipherText),
    tag: Uint8List.fromList(secretBox.mac.bytes),
  );
}

Future<Uint8List> _decryptAesGcmStable({
  required Uint8List ciphertext,
  required Uint8List key,
  required Uint8List iv,
  required Uint8List tag,
}) async {
  final algorithm = crypto_graphy.AesGcm.with256bits();
  final clear = await algorithm.decrypt(
    crypto_graphy.SecretBox(
      ciphertext,
      nonce: iv,
      mac: crypto_graphy.Mac(tag),
    ),
    secretKey: crypto_graphy.SecretKey(key),
  );
  return Uint8List.fromList(clear);
}

class _EncryptParams {
  final Uint8List plaintext;
  final Uint8List key;
  final Uint8List iv;

  const _EncryptParams({
    required this.plaintext,
    required this.key,
    required this.iv,
  });
}

class _EncryptResult {
  final Uint8List ciphertext;
  final Uint8List tag;

  const _EncryptResult({required this.ciphertext, required this.tag});
}

class _DecryptParams {
  final Uint8List ciphertext;
  final Uint8List key;
  final Uint8List iv;
  final Uint8List tag;

  const _DecryptParams({
    required this.ciphertext,
    required this.key,
    required this.iv,
    required this.tag,
  });
}

_EncryptResult _encryptAesGcm(_EncryptParams p) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(p.key), 128, p.iv, Uint8List(0)));
  final out = Uint8List(cipher.getOutputSize(p.plaintext.length));
  var offset = 0;
  offset += cipher.processBytes(p.plaintext, 0, p.plaintext.length, out, offset);
  offset += cipher.doFinal(out, offset);
  // out contine: [0..offset-17] = ciphertext, [offset-16..offset-1] = tag (16 bytes GCM)
  // getOutputSize garanteaza ca out.length == p.plaintext.length + 16
  return _EncryptResult(
    ciphertext: out.sublist(0, out.length - 16),
    tag: out.sublist(out.length - 16),
  );
}

Uint8List _decryptAesGcm(_DecryptParams p) {
  if (p.ciphertext.isEmpty) {
    throw Exception('Empty ciphertext — the downloaded file seems invalid');
  }

  final input = Uint8List(p.ciphertext.length + p.tag.length)
    ..setAll(0, p.ciphertext)
    ..setAll(p.ciphertext.length, p.tag);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(p.key), 128, p.iv, Uint8List(0)));
  final out = Uint8List(cipher.getOutputSize(input.length));
  var offset = 0;
  offset += cipher.processBytes(input, 0, input.length, out, offset);
  // doFinal verifying tag-ul GCM și aruncă InvalidCipherTextException dacă nu se potrivește.
  // Returnează numărul de bytes scriși (plaintext final) — trebuie adăugat la offset.
  offset += cipher.doFinal(out, offset);
  return out.sublist(0, offset);
}

Map<String, Uint8List> _encryptAesGcmForCompute(Map<String, Uint8List> p) {
  final result = _encryptAesGcm(_EncryptParams(
    plaintext: p['plaintext']!,
    key: p['key']!,
    iv: p['iv']!,
  ));
  return {
    'ciphertext': result.ciphertext,
    'tag': result.tag,
  };
}

Uint8List _decryptAesGcmForCompute(Map<String, Uint8List> p) {
  return _decryptAesGcm(_DecryptParams(
    ciphertext: p['ciphertext']!,
    key: p['key']!,
    iv: p['iv']!,
    tag: p['tag']!,
  ));
}
