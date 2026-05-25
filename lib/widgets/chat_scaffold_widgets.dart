import 'package:flutter/material.dart';

import '../theme/secure_chat_theme.dart';

class TransferStatusBanner extends StatelessWidget {
  final String text;
  final bool isError;
  final bool isBusy;

  const TransferStatusBanner({
    super.key,
    required this.text,
    required this.isError,
    required this.isBusy,
  });

  static double _progressFor(String text) {
    final t = text.toLowerCase();
    if (t.contains('preparing') || t.contains('pregateste')) return 0.10;
    if (t.contains('encrypting') || t.contains('cripteaza')) return 0.30;
    if (t.contains('uploading') || t.contains('incarca')) return 0.60;
    if (t.contains('verifying') || t.contains('verifica')) return 0.85;
    if (t.contains('finalizing') || t.contains('finalizeaza')) return 0.95;
    if (t.contains('trimis') || t.contains('success')) return 1.0;
    return 0.50;
  }

  @override
  Widget build(BuildContext context) {
    final accent = isError ? SecureChatColors.danger : SecureChatColors.turquoise;
    final progress = isBusy && !isError ? _progressFor(text) : (isError ? 0.0 : 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        decoration: BoxDecoration(
          color: SecureChatColors.card.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (isBusy && !isError)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: SecureChatColors.turquoise,
                    ),
                  )
                else
                  Icon(
                    isError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    color: accent,
                    size: 18,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isError
                          ? SecureChatColors.danger
                          : SecureChatColors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isBusy && !isError)
                  Text(
                    '${(progress * 100).round()}%',
                    style: const TextStyle(
                      color: SecureChatColors.turquoise,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            if (isBusy && !isError) ...[
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: SecureChatColors.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    SecureChatColors.turquoise,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ChatHeader extends StatelessWidget {
  final String peerLabel;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onReconnect;
  final VoidCallback onDelete;

  const ChatHeader({
    super.key,
    required this.peerLabel,
    required this.statusLabel,
    required this.statusColor,
    required this.onReconnect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        peerLabel.isNotEmpty ? peerLabel.substring(0, 1).toUpperCase() : '?';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded,
                color: SecureChatColors.text),
            onPressed: () => Navigator.pop(context),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SecureChatAvatar.gradientFor(peerLabel),
            ),
            child: Center(
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peerLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SecureChatColors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            color: SecureChatColors.mutedText,
            tooltip: 'Reconnect',
            onPressed: onReconnect,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            color: SecureChatColors.danger,
            tooltip: 'Delete conversation',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.isSending,
    required this.onSend,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 13),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
          decoration: BoxDecoration(
            color: SecureChatColors.card.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(SecureChatRadius.xxl),
            border: Border.all(
                color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
            boxShadow: SecureChatShadows.card,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: isSending ? null : onAttach,
                icon: const Icon(Icons.attach_file_rounded),
                color: SecureChatColors.mutedText,
                tooltip: 'Attachment',
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  style: const TextStyle(color: SecureChatColors.text),
                  decoration: const InputDecoration(
                    hintText: 'Write a message...',
                    hintStyle: TextStyle(color: SecureChatColors.mutedText),
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              isSending
                  ? const SizedBox(
                      width: 42,
                      height: 42,
                      child: Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : SizedBox(
                      width: 46,
                      height: 46,
                      child: FilledButton(
                        onPressed: onSend,
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero,
                          shape: const CircleBorder(),
                          backgroundColor: SecureChatColors.violet,
                        ),
                        child: const Icon(Icons.send_rounded,
                            size: 22, color: Colors.white),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyChat extends StatelessWidget {
  final String peerLabel;
  const EmptyChat({super.key, required this.peerLabel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline_rounded,
              size: 48, color: SecureChatColors.mutedText),
          const SizedBox(height: 16),
          Text(
            'Encrypted conversation with\n$peerLabel',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: SecureChatColors.mutedText,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}
