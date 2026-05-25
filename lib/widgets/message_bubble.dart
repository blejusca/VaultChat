import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';

import '../models/message_model.dart';
import '../theme/secure_chat_theme.dart';
import '../services/file_transfer_service.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isMine = message.isMine;
    final displayLabel = _safeDisplayLabel(message.senderLabel, message.senderPublicKey);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5.5),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) _Avatar(label: displayLabel, seed: message.senderPublicKey),
          if (!isMine) const SizedBox(width: 8),
          Flexible(
            child: AnimatedContainer(
              duration: SecureChatMotion.fast,
              curve: SecureChatMotion.curve,
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.76,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              decoration: BoxDecoration(
                gradient: isMine ? SecureChatGradients.primary : null,
                color: isMine ? null : SecureChatColors.cardAlt.withValues(alpha: 0.88),
                border: isMine
                    ? null
                    : Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
                boxShadow: isMine ? SecureChatShadows.subtleGlow : null,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(21),
                  topRight: const Radius.circular(21),
                  bottomLeft: Radius.circular(isMine ? 21 : 7),
                  bottomRight: Radius.circular(isMine ? 7 : 21),
                ),
              ),
              child: message.hasAttachment
                  ? _AttachmentBubble(message: message, isMine: isMine)
                  : Column(
                crossAxisAlignment:
                    isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isMine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        message.senderLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: SecureChatColors.violetSoft,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  Text(
                    message.text,
                    style: const TextStyle(
                      color: SecureChatColors.text,
                      fontSize: 15.5,
                      height: 1.3,
                      letterSpacing: 0.02,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.createdAt),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isMine
                              ? Colors.white.withValues(alpha: 0.74)
                              : SecureChatColors.softText,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.done_rounded,
                          size: 13,
                          color: Colors.white.withValues(alpha: 0.74),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isMine) const SizedBox(width: 8),
          if (isMine) _MineAvatar(seed: message.senderPublicKey),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}

String _safeDisplayLabel(String label, String publicKey) {
  final clean = label.trim();
  final key = publicKey.trim().toLowerCase();
  final looksTechnical = clean.isEmpty ||
      clean.toLowerCase() == 'unknown contact' ||
      clean.toLowerCase() == 'unknown contact' ||
      clean.toLowerCase() == key ||
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(clean);

  if (!looksTechnical) return clean;
  if (key.length >= 8) return key.substring(0, 8);
  return 'Unknown';
}

class _Avatar extends StatelessWidget {
  final String label;
  final String seed;

  const _Avatar({required this.label, required this.seed});

  @override
  Widget build(BuildContext context) {
    final letter = label.isNotEmpty ? label.substring(0, 1).toUpperCase() : '?';

    return Container(
      width: 30,
      height: 30,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        gradient: SecureChatAvatar.gradientFor(seed.isNotEmpty ? seed : label),
        shape: BoxShape.circle,
        boxShadow: SecureChatShadows.subtleGlow,
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SecureChatColors.deepNavy.withValues(alpha: 0.18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Center(
          child: Text(
            letter,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _MineAvatar extends StatelessWidget {
  final String seed;

  const _MineAvatar({required this.seed});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: SecureChatAvatar.gradientFor(seed.isNotEmpty ? seed : 'me'),
        shape: BoxShape.circle,
        boxShadow: SecureChatShadows.subtleGlow,
      ),
      child: const Icon(Icons.person_rounded, size: 15, color: Colors.white),
    );
  }
}

// ─── ATTACHMENT BUBBLE ────────────────────────────────────────────────────────

class _AttachmentBubble extends StatefulWidget {
  final MessageModel message;
  final bool isMine;

  const _AttachmentBubble({required this.message, required this.isMine});

  @override
  State<_AttachmentBubble> createState() => _AttachmentBubbleState();
}

class _AttachmentBubbleState extends State<_AttachmentBubble> {
  bool _loading = false;
  String? _error;
  Uint8List? _imageBytes;

  AttachmentMeta get _meta => widget.message.attachment!;

  @override
  void initState() {
    super.initState();
    // Nu descărcăm automat imaginile mari. Pe telefoane mai slabe asta poate
    // bloca UI-ul și poate declanșa ANR. Imaginile mici se pot previzualiza automat.
    if (_meta.type == AttachmentType.image && _meta.fileSize <= 350 * 1024) {
      _download();
    }
  }

  Future<void> _download() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final bytes = await FileTransferService.downloadAndDecrypt(
        url: _meta.url, encKeyHex: _meta.encKey,
        encIvHex: _meta.encIv, encTagHex: _meta.encTag,
        blobSha256: _meta.blobSha256,
      );
      if (!mounted) return;
      setState(() { _imageBytes = bytes; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Download error: $e'; _loading = false; });
    }
  }

  Future<void> _downloadAndOpenPdf() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final bytes = await FileTransferService.downloadAndDecrypt(
        url: _meta.url, encKeyHex: _meta.encKey,
        encIvHex: _meta.encIv, encTagHex: _meta.encTag,
        blobSha256: _meta.blobSha256,
      );
      final safeName = _meta.fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$safeName');
      await file.writeAsBytes(bytes);
      final result = await OpenFilex.open(file.path);
      if (!mounted) return;
      setState(() { _loading = false; });
      if (result.type != ResultType.done) {
        setState(() { _error = 'Could not open it. Do you have a PDF app?'; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Error: $e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMine = widget.isMine;
    final displayLabel = _safeDisplayLabel(widget.message.senderLabel, widget.message.senderPublicKey);
    final time = '${widget.message.createdAt.hour.toString().padLeft(2, '0')}:'
        '${widget.message.createdAt.minute.toString().padLeft(2, '0')}';

    return Column(
      crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (!isMine)
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 4, top: 2),
            child: Text(displayLabel,
                style: const TextStyle(fontSize: 11,
                    color: SecureChatColors.violetSoft, fontWeight: FontWeight.w700)),
          ),
        if (_meta.type == AttachmentType.image)
          _ImagePreview(
            imageBytes: _imageBytes,
            loading: _loading,
            error: _error,
            onRetry: _download,
            fileName: _meta.fileName,
            fileSize: _meta.fileSize,
          )
        else
          _PdfCard(meta: _meta, loading: _loading, error: _error, onOpen: _downloadAndOpenPdf),
        Padding(
          padding: const EdgeInsets.only(top: 4, right: 6, left: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(time, style: TextStyle(fontSize: 10.5,
                  color: isMine ? Colors.white.withValues(alpha: 0.74) : SecureChatColors.softText,
                  fontWeight: FontWeight.w500)),
              if (isMine) ...[
                const SizedBox(width: 4),
                Icon(Icons.done_rounded, size: 13, color: Colors.white.withValues(alpha: 0.74)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}


String _compactTransferError(String error) {
  var value = error.replaceFirst('Download error: ', '').replaceFirst('Error: ', '').trim();
  if (value.contains('SecretBoxAuthenticationError') || value.contains('InvalidCipherTextException') || value.contains('decript')) {
    return 'The downloaded file cannot be decrypted. Tap to retry.';
  }
  if (value.contains('HTTP 404')) {
    return 'Expired or invalid link on server. Resend the file.';
  }
  if (value.length > 110) {
    value = '${value.substring(0, 110)}…';
  }
  return value;
}

// ─── IMAGE PREVIEW ────────────────────────────────────────────────────────────

class _ImagePreview extends StatelessWidget {
  final Uint8List? imageBytes;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final String fileName;
  final int fileSize;

  const _ImagePreview({
    required this.imageBytes,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.fileName,
    required this.fileSize,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        width: 220, height: 160,
        decoration: BoxDecoration(color: SecureChatColors.card,
            borderRadius: BorderRadius.circular(14)),
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(strokeWidth: 2),
          SizedBox(height: 10),
          Text('Downloading...', style: TextStyle(color: SecureChatColors.mutedText, fontSize: 12)),
        ])),
      );
    }
    if (error != null) {
      return GestureDetector(
        onTap: onRetry,
        child: Container(
          width: 220,
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(color: SecureChatColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: SecureChatColors.danger.withValues(alpha: 0.4))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.refresh_rounded, color: SecureChatColors.danger, size: 24),
            const SizedBox(height: 5),
            Text(
              _compactTransferError(error!),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: SecureChatColors.danger, fontSize: 11.5),
            ),
            const SizedBox(height: 4),
            const Text('Tap to retry',
                style: TextStyle(color: SecureChatColors.mutedText, fontSize: 11)),
          ]),
        ),
      );
    }
    if (imageBytes != null) {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.black,
                iconTheme: const IconThemeData(color: Colors.white)),
            body: Center(child: InteractiveViewer(child: Image.memory(imageBytes!))),
          ),
        )),
        child: ClipRRect(borderRadius: BorderRadius.circular(14),
            child: Image.memory(imageBytes!, width: 220, fit: BoxFit.cover)),
      );
    }
    return GestureDetector(
      onTap: onRetry,
      child: Container(
        width: 220,
        constraints: const BoxConstraints(minHeight: 112),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: SecureChatColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_rounded, color: SecureChatColors.violetSoft, size: 28),
            const SizedBox(height: 8),
            Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SecureChatColors.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _fmtSize(fileSize),
              style: const TextStyle(color: SecureChatColors.mutedText, fontSize: 11),
            ),
            const SizedBox(height: 7),
            const Text(
              'Tap to download',
              style: TextStyle(color: SecureChatColors.turquoise, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ─── PDF CARD ─────────────────────────────────────────────────────────────────

class _PdfCard extends StatelessWidget {
  final AttachmentMeta meta;
  final bool loading;
  final String? error;
  final VoidCallback onOpen;

  const _PdfCard({required this.meta, required this.loading,
      required this.error, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: SecureChatColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.6))),
      child: Row(children: [
        Container(width: 40, height: 40,
            decoration: BoxDecoration(
                color: SecureChatColors.violet.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.picture_as_pdf_rounded,
                color: SecureChatColors.violetSoft, size: 22)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(meta.fileName, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: SecureChatColors.text,
                  fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(_fmtSize(meta.fileSize),
              style: const TextStyle(color: SecureChatColors.mutedText, fontSize: 11)),
          if (error != null)
            Padding(padding: const EdgeInsets.only(top: 3),
                child: Text(
                  _compactTransferError(error!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SecureChatColors.danger, fontSize: 11),
                )),
        ])),
        const SizedBox(width: 8),
        loading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                onPressed: onOpen,
                icon: Icon(error != null ? Icons.refresh_rounded : Icons.open_in_new_rounded,
                    color: SecureChatColors.turquoise, size: 22),
                tooltip: error != null ? 'Retry' : 'Deschide PDF',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints()),
      ]),
    );
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
