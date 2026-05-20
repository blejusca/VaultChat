import 'package:flutter/material.dart';

import '../models/conversation_model.dart';
import '../services/nostr_connection_service.dart';
import '../theme/secure_chat_theme.dart';

class InboxScreen extends StatelessWidget {
  final List<ConversationModel> conversations;
  final SecureChatConnectionSnapshot connectionSnapshot;
  final String myPublicKey;
  final ValueChanged<ConversationModel> onOpenConversation;
  final VoidCallback onNewConversation;
  final VoidCallback onAddContact;
  final VoidCallback onManualReconnect;
  final VoidCallback onShowKeys;
  final VoidCallback onOpenLastConversation;

  const InboxScreen({
    super.key,
    required this.conversations,
    required this.connectionSnapshot,
    required this.myPublicKey,
    required this.onOpenConversation,
    required this.onNewConversation,
    required this.onAddContact,
    required this.onManualReconnect,
    required this.onShowKeys,
    required this.onOpenLastConversation,
  });

  Color _statusColor() {
    switch (connectionSnapshot.state) {
      case SecureChatConnectionState.connected:
        return SecureChatColors.turquoise;
      case SecureChatConnectionState.connecting:
      case SecureChatConnectionState.reconnecting:
      case SecureChatConnectionState.idle:
        return SecureChatColors.warning;
      case SecureChatConnectionState.offline:
      case SecureChatConnectionState.error:
        return SecureChatColors.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _PremiumFab(onPressed: onNewConversation),
      body: Container(
        decoration: const BoxDecoration(gradient: SecureChatGradients.background),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => onManualReconnect(),
            color: SecureChatColors.violetBright,
            backgroundColor: SecureChatColors.card,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _InboxHeader(
                    connectionLabel: connectionSnapshot.label,
                    statusColor: _statusColor(),
                    onManualReconnect: onManualReconnect,
                    onShowKeys: onShowKeys,
                    onAddContact: onAddContact,
                  ),
                ),
                if (conversations.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyInbox(onNewConversation: onNewConversation),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 118),
                    sliver: SliverList.separated(
                      itemCount: conversations.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        return AnimatedSwitcher(
                          duration: SecureChatMotion.normal,
                          child: _ConversationTile(
                            key: ValueKey(conversation.id),
                            conversation: conversation,
                            onTap: () => onOpenConversation(conversation),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InboxHeader extends StatelessWidget {
  final String connectionLabel;
  final Color statusColor;
  final VoidCallback onManualReconnect;
  final VoidCallback onShowKeys;
  final VoidCallback onAddContact;

  const _InboxHeader({
    required this.connectionLabel,
    required this.statusColor,
    required this.onManualReconnect,
    required this.onShowKeys,
    required this.onAddContact,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RichText(
                      text: const TextSpan(
                        children: [
                          TextSpan(
                            text: 'Vault',
                            style: TextStyle(
                              color: SecureChatColors.text,
                              fontSize: 29,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.8,
                            ),
                          ),
                          TextSpan(
                            text: 'Chat',
                            style: TextStyle(
                              color: SecureChatColors.violetBright,
                              fontSize: 29,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 7),
                    _StatusPill(
                      label: connectionLabel,
                      color: statusColor,
                    ),
                  ],
                ),
              ),
              _HeaderIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Reconecteaza manual',
                onPressed: onManualReconnect,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                icon: Icons.person_add_alt_1_rounded,
                tooltip: 'Contact nou',
                onPressed: onAddContact,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                icon: Icons.key_rounded,
                tooltip: 'Identitatea ta',
                onPressed: onShowKeys,
              ),
            ],
          ),
          const SizedBox(height: 19),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: SecureChatColors.card.withValues(alpha: 0.68),
              borderRadius: BorderRadius.circular(SecureChatRadius.lg),
              border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.72)),
            ),
            child: const Row(
              children: [
                Icon(Icons.search_rounded, color: SecureChatColors.softText, size: 20),
                SizedBox(width: 10),
                Text(
                  'Conversații criptate',
                  style: TextStyle(color: SecureChatColors.mutedText, fontSize: 14),
                ),
                Spacer(),
                Icon(Icons.lock_outline_rounded, color: SecureChatColors.turquoise, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: color == SecureChatColors.turquoise
                ? SecureChatShadows.greenGlow
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Ink(
            width: 43,
            height: 43,
            decoration: BoxDecoration(
              color: SecureChatColors.card.withValues(alpha: 0.72),
              shape: BoxShape.circle,
              border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.65)),
            ),
            child: Icon(icon, color: SecureChatColors.mutedText, size: 21),
          ),
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  final VoidCallback onNewConversation;

  const _EmptyInbox({required this.onNewConversation});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 120),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
          decoration: BoxDecoration(
            gradient: SecureChatGradients.card,
            borderRadius: BorderRadius.circular(SecureChatRadius.xl),
            border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.75)),
            boxShadow: SecureChatShadows.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  color: SecureChatColors.violet.withValues(alpha: 0.13),
                  shape: BoxShape.circle,
                  border: Border.all(color: SecureChatColors.violetBright.withValues(alpha: 0.18)),
                ),
                child: const Icon(
                  Icons.lock_outline_rounded,
                  size: 39,
                  color: SecureChatColors.violetSoft,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Nu ai conversații încă.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: SecureChatColors.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pornește un chat folosind cheia publică Nostr a destinatarului.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: SecureChatColors.mutedText,
                  height: 1.45,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 23),
              FilledButton.icon(
                onPressed: onNewConversation,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Conversație nouă'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final ConversationModel conversation;
  final VoidCallback onTap;

  const _ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final peerLabel = conversation.peerLabel.trim().isNotEmpty
        ? conversation.peerLabel.trim()
        : 'Contact necunoscut';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(SecureChatRadius.xl),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            gradient: SecureChatGradients.card,
            borderRadius: BorderRadius.circular(SecureChatRadius.xl),
            border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
            boxShadow: SecureChatShadows.soft,
          ),
          child: Row(
            children: [
              _Avatar(label: peerLabel, seed: conversation.peerPublicKey),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            peerLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: SecureChatColors.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTime(conversation.updatedAt),
                          style: const TextStyle(
                            fontSize: 12,
                            color: SecureChatColors.softText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.lock_outline_rounded, size: 13, color: SecureChatColors.turquoise),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            conversation.lastMessageText.isEmpty
                                ? 'Conversație criptată'
                                : conversation.lastMessageText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: SecureChatColors.mutedText,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: SecureChatColors.cardSoft.withValues(alpha: 0.72),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.chevron_right_rounded,
                  color: SecureChatColors.mutedText,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }static String _formatTime(DateTime time) {
    final now = DateTime.now();
    final sameDay = now.year == time.year &&
        now.month == time.month &&
        now.day == time.day;

    if (sameDay) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }

    return '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}';
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
      width: 56,
      height: 56,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SecureChatAvatar.gradientFor(seed.isNotEmpty ? seed : label),
        boxShadow: SecureChatShadows.subtleGlow,
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SecureChatColors.deepNavy.withValues(alpha: 0.10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Center(
          child: Text(
            letter,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _PremiumFab extends StatelessWidget {
  final VoidCallback onPressed;

  const _PremiumFab({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SecureChatRadius.xl),
        boxShadow: SecureChatShadows.subtleGlow,
      ),
      child: FloatingActionButton.extended(
        onPressed: onPressed,
        elevation: 0,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('Chat nou'),
      ),
    );
  }
}
