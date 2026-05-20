import 'package:flutter/material.dart';

import '../models/message_model.dart';
import '../theme/secure_chat_theme.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isMine = message.isMine;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5.5),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) _Avatar(label: message.senderLabel, seed: message.senderPublicKey),
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
              child: Column(
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
