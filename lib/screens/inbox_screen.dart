import 'package:flutter/material.dart';

import '../models/conversation_model.dart';
import '../services/nostr_connection_service.dart';
import '../theme/secure_chat_theme.dart';

class InboxScreen extends StatefulWidget {
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

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _showAllContacts = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _statusColor() {
    switch (widget.connectionSnapshot.state) {
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

  bool _matchesQuery(ConversationModel conversation) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return conversation.peerLabel.toLowerCase().contains(q) ||
        conversation.peerPublicKey.toLowerCase().contains(q) ||
        conversation.peerPublicKey.toLowerCase().startsWith(q);
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = _query.trim().isNotEmpty;
    final matchingConversations = widget.conversations.where(_matchesQuery).toList();
    const recentLimit = 8;
    final visibleConversations = !hasQuery && !_showAllContacts
        ? matchingConversations.take(recentLimit).toList()
        : matchingConversations;
    final hiddenCount = matchingConversations.length - visibleConversations.length;
    final sectionTitle = hasQuery
        ? 'Search results'
        : _showAllContacts
            ? 'All contacts'
            : 'Recent conversations';

    return Scaffold(
      floatingActionButton: _PremiumFab(onPressed: widget.onNewConversation),
      body: Container(
        decoration: const BoxDecoration(gradient: SecureChatGradients.background),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => widget.onManualReconnect(),
            color: SecureChatColors.violetBright,
            backgroundColor: SecureChatColors.card,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _InboxHeader(
                    connectionLabel: widget.connectionSnapshot.label,
                    statusColor: _statusColor(),
                    onManualReconnect: widget.onManualReconnect,
                    onShowKeys: widget.onShowKeys,
                    onAddContact: widget.onAddContact,
                    searchController: _searchController,
                    onSearchChanged: (value) {
                      setState(() {
                        _query = value;
                        if (value.trim().isNotEmpty) {
                          _showAllContacts = true;
                        }
                      });
                    },
                  ),
                ),
                if (widget.conversations.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyInbox(onNewConversation: widget.onNewConversation),
                  )
                else if (visibleConversations.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _NoSearchResults(),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: _InboxSectionHeader(
                      title: sectionTitle,
                      count: matchingConversations.length,
                      showCompactHint: !hasQuery && !_showAllContacts && hiddenCount > 0,
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(18, 8, 18, hiddenCount > 0 ? 12 : 118),
                    sliver: SliverList.separated(
                      itemCount: visibleConversations.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final conversation = visibleConversations[index];
                        return AnimatedSwitcher(
                          duration: SecureChatMotion.normal,
                          child: _ConversationTile(
                            key: ValueKey(conversation.id),
                            conversation: conversation,
                            onTap: () => widget.onOpenConversation(conversation),
                          ),
                        );
                      },
                    ),
                  ),
                  if (!hasQuery && hiddenCount > 0)
                    SliverToBoxAdapter(
                      child: _ShowAllContactsButton(
                        hiddenCount: hiddenCount,
                        onPressed: () => setState(() => _showAllContacts = true),
                      ),
                    ),
                  if (!hasQuery && _showAllContacts && matchingConversations.length > recentLimit)
                    SliverToBoxAdapter(
                      child: _CollapseContactsButton(
                        onPressed: () => setState(() => _showAllContacts = false),
                      ),
                    ),
                ],
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
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;

  const _InboxHeader({
    required this.connectionLabel,
    required this.statusColor,
    required this.onManualReconnect,
    required this.onShowKeys,
    required this.onAddContact,
    required this.searchController,
    required this.onSearchChanged,
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
                tooltip: 'Reconnect manually',
                onPressed: onManualReconnect,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                icon: Icons.person_add_alt_1_rounded,
                tooltip: 'New contact',
                onPressed: onAddContact,
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                icon: Icons.key_rounded,
                tooltip: 'Your identity',
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
            child: Row(
              children: [
                const Icon(Icons.search_rounded, color: SecureChatColors.softText, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: searchController,
                    onChanged: onSearchChanged,
                    style: const TextStyle(color: SecureChatColors.text, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Search contacts...',
                      hintStyle: TextStyle(color: SecureChatColors.mutedText, fontSize: 14),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                const Icon(Icons.lock_outline_rounded, color: SecureChatColors.turquoise, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class _InboxSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool showCompactHint;

  const _InboxSectionHeader({
    required this.title,
    required this.count,
    required this.showCompactHint,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title ($count)',
              style: const TextStyle(
                color: SecureChatColors.softText,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.1,
              ),
            ),
          ),
          if (showCompactHint)
            const Text(
              'compact display',
              style: TextStyle(
                color: SecureChatColors.mutedText,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _ShowAllContactsButton extends StatelessWidget {
  final int hiddenCount;
  final VoidCallback onPressed;

  const _ShowAllContactsButton({
    required this.hiddenCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 118),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more_rounded),
        label: Text('View all contacts (+$hiddenCount)'),
      ),
    );
  }
}

class _CollapseContactsButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _CollapseContactsButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 118),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.expand_less_rounded),
        label: const Text('Show only recent conversations'),
      ),
    );
  }
}

class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 60, 24, 120),
        child: Text(
          'No conversations found for this search.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: SecureChatColors.mutedText,
            fontSize: 14,
            height: 1.35,
          ),
        ),
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
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
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
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 26),
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
                'Welcome to VaultChat!',
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
                'End-to-end encrypted messages on the Nostr protocol.\nNo one else can read your conversations.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: SecureChatColors.mutedText,
                  height: 1.5,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 22),
              // Onboarding steps
              _OnboardingStep(
                number: '1',
                icon: Icons.key_rounded,
                title: 'Your identity is ready',
                subtitle: 'Your Nostr public key was generated automatically and stored securely.',
              ),
              const SizedBox(height: 10),
              _OnboardingStep(
                number: '2',
                icon: Icons.person_add_rounded,
                title: 'Add a contact',
                subtitle: 'Ask for the Nostr public key (64 hex characters) of the person you want to contact.',
              ),
              const SizedBox(height: 10),
              _OnboardingStep(
                number: '3',
                icon: Icons.chat_bubble_outline_rounded,
                title: 'Send the first message',
                subtitle: 'The message is encrypted with NIP-44 v2 directly on the device before it leaves for the relay.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onNewConversation,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Start a conversation'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingStep extends StatelessWidget {
  final String number;
  final IconData icon;
  final String title;
  final String subtitle;

  const _OnboardingStep({
    required this.number,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: SecureChatColors.midnight.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SecureChatColors.border.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: SecureChatColors.violet.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: SecureChatColors.violetBright),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: SecureChatColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: SecureChatColors.mutedText,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
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
        : 'Unknown contact';

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
                                ? 'Encrypted conversation'
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
        label: const Text('New chat'),
      ),
    );
  }
}
