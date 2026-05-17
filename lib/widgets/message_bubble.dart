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
          if (!isMine) _Avatar(label: message.senderLabel),
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
                color: isMine ? null : SecureChatColors.cardAlt.withOpacity(0.88),
                border: isMine
                    ? null
                    : Border.all(color: SecureChatColors.borderSoft.withOpacity(0.62)),
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
                              ? Colors.white.withOpacity(0.74)
                              : SecureChatColors.softText,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.done_all_rounded,
                          size: 13,
                          color: Colors.white.withOpacity(0.74),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isMine) const SizedBox(width: 8),
          if (isMine) const _MineAvatar(),
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

  const _Avatar({required this.label});

  @override
  Widget build(BuildContext context) {
    final letter = label.isNotEmpty ? label.substring(0, 1).toUpperCase() : '?';

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: SecureChatColors.cardAlt.withOpacity(0.88),
        shape: BoxShape.circle,
        border: Border.all(color: SecureChatColors.borderSoft.withOpacity(0.62)),
      ),
      child: Center(
        child: Text(
          letter,
          style: const TextStyle(
            fontSize: 12,
            color: SecureChatColors.violetSoft,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _MineAvatar extends StatelessWidget {
  const _MineAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: const BoxDecoration(
        gradient: SecureChatGradients.primary,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.person_rounded, size: 15, color: Colors.white),
    );
  }
}
