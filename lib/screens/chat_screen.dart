import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message_model.dart';
import '../services/conversation_storage_service.dart';
import '../services/nostr_connection_service.dart';
import '../theme/secure_chat_theme.dart';
import '../widgets/message_bubble.dart';
import 'chat_controller.dart';

/// Ecranul de chat — exclusiv UI.
/// All logic (send, upload, pagination, subscriptions) is in [ChatController].
class ChatScreen extends StatefulWidget {
  final String recipientPublicKey;
  final String myPublicKey;
  final String peerLabel;
  final ConversationStorageService storageService;
  final NostrConnectionService connectionService;
  final Future<void> Function() onConversationChanged;
  final Future<void> Function(String peerPublicKey)? onConversationDeleted;
  /// Contact display names keyed by lowercased public key.
  /// Must be populated before this widget is built so sender labels are
  /// correct from the first frame (Req 9).
  final Map<String, String> contactsMap;

  const ChatScreen({
    super.key,
    required this.recipientPublicKey,
    required this.myPublicKey,
    required this.peerLabel,
    required this.storageService,
    required this.connectionService,
    required this.onConversationChanged,
    this.onConversationDeleted,
    this.contactsMap = const {},
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _ctrl;
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  StreamSubscription<ChatState>? _stateSub;
  ChatState _state = ChatState.initial(SecureChatConnectionSnapshot(
    state: SecureChatConnectionState.idle, label: '', updatedAt: DateTime.now()));
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _ctrl = ChatController(
      recipientPublicKey: widget.recipientPublicKey,
      myPublicKey: widget.myPublicKey,
      storageService: widget.storageService,
      connectionService: widget.connectionService,
      onConversationChanged: widget.onConversationChanged,
      onConversationDeleted: widget.onConversationDeleted,
      // Req 9: contacts must be loaded before rendering sender display names.
      contactsMap: widget.contactsMap,
    );
    _stateSub = _ctrl.stateStream.listen((s) {
      if (!mounted) return;
      final wasAtBottom = _isAtBottom();
      setState(() => _state = s);
      if (wasAtBottom) _scrollToBottom();
    });
    _state = _ctrl.state;

    // Scroll listener for pagination when scrolling up
    _scrollCtrl.addListener(_onScroll);
  }

  bool _isAtBottom() {
    if (!_scrollCtrl.hasClients) return true;
    final pos = _scrollCtrl.position;
    return pos.pixels >= pos.maxScrollExtent - 80;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _onScroll() async {
    if (_isLoadingMore) return;
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels > 80) return; // not at the top
    if (!_ctrl.hasMoreMessages) return;

    _isLoadingMore = true;
    final oldOffset = _scrollCtrl.position.pixels;
    final oldMax = _scrollCtrl.position.maxScrollExtent;
    final loaded = await _ctrl.loadMoreMessages();
    if (loaded && mounted) {
      // Keep scroll position after inserting older messages above
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        final newMax = _scrollCtrl.position.maxScrollExtent;
        _scrollCtrl.jumpTo(oldOffset + (newMax - oldMax));
      });
    }
    _isLoadingMore = false;
  }

  Future<bool> _isConversationDeletedOrClosed() async {
    if (_state.isConversationClosed) return true;
    final deleted = await widget.storageService.isConversationDeleted(_ctrl.conversationId);
    if (!deleted) return false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This conversation was deleted. Create a new one to continue.'),
        ),
      );
    }
    return true;
  }

  Future<void> _sendMessage() async {
    if (await _isConversationDeletedOrClosed()) return;
    final text = _textCtrl.text;
    _textCtrl.clear();
    try {
      await _ctrl.sendMessage(text);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send error: $e'),
              backgroundColor: SecureChatColors.danger),
        );
      }
    }
  }

  void _showAttachOptions() {
    if (_state.isConversationClosed) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SecureChatColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: SecureChatColors.borderSoft,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.camera_alt_rounded, color: SecureChatColors.turquoise),
            title: const Text('Camera'),
            onTap: () { Navigator.pop(context); _ctrl.sendFromCamera(); },
          ),
          ListTile(
            leading: const Icon(Icons.image_rounded, color: SecureChatColors.violetBright),
            title: const Text('Photo Gallery'),
            onTap: () { Navigator.pop(context); _ctrl.sendFromGallery(); },
          ),
          ListTile(
            leading: const Icon(Icons.attach_file_rounded, color: SecureChatColors.mutedText),
            title: const Text('File'),
            onTap: () { Navigator.pop(context); _ctrl.pickAndSendFile(); },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SecureChatColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(SecureChatRadius.xl)),
        icon: const Icon(Icons.delete_outline_rounded, color: SecureChatColors.danger),
        title: const Text('Delete conversation?', textAlign: TextAlign.center,
            style: TextStyle(color: SecureChatColors.text, fontWeight: FontWeight.w800)),
        content: const Text(
          'The conversation will be deleted immediately on this device. The other device will be notified and will delete it when it receives the command through the relay.\n\nThis action is irreversible.',
          textAlign: TextAlign.center,
          style: TextStyle(color: SecureChatColors.mutedText, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: SecureChatColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _ctrl.deleteConversation();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _ctrl.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = _state.connectionSnapshot;
    final isConnected = snap.state == SecureChatConnectionState.connected;
    final isConnecting = snap.state == SecureChatConnectionState.connecting ||
        snap.state == SecureChatConnectionState.reconnecting;

    return Scaffold(
      backgroundColor: SecureChatColors.deepNavy,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _ChatHeader(
            peerLabel: widget.peerLabel,
            statusLabel: isConnected ? 'Connected' : isConnecting ? 'Connecting...' : 'Disconnected',
            statusColor: isConnected
                ? SecureChatColors.turquoise
                : isConnecting ? SecureChatColors.warning : SecureChatColors.danger,
            onReconnect: () => widget.connectionService.refreshIfNeeded(reason: 'Manual'),
            onDelete: _confirmDelete,
          ),
          // Indicator "loading more"
          if (_isLoadingMore)
            const LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: SecureChatColors.card,
              color: SecureChatColors.violetBright,
            ),
          Expanded(
            child: _state.messages.isEmpty
                ? _EmptyChat(peerLabel: widget.peerLabel)
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: _state.messages.length,
                    itemBuilder: (ctx, i) => MessageBubble(message: _state.messages[i]),
                  ),
          ),
          if (_state.transferStatus != null)
            _TransferStatusBanner(
              text: _state.transferStatus!,
              isError: _state.transferStatusIsError,
              isBusy: _state.isUploadingAttachment,
              progress: _state.uploadProgress,
            ),
          _Composer(
            controller: _textCtrl,
            isSending: _state.isSending || _state.isUploadingAttachment,
            onSend: _sendMessage,
            onAttach: _showAttachOptions,
          ),
        ]),
      ),
    );
  }
}

// ─── TRANSFER BANNER ──────────────────────────────────────────────────────────

class _TransferStatusBanner extends StatelessWidget {
  final String text;
  final bool isError;
  final bool isBusy;
  final double progress;

  const _TransferStatusBanner({
    required this.text,
    required this.isError,
    required this.isBusy,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isError ? SecureChatColors.danger : SecureChatColors.turquoise;
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
            Row(children: [
              if (isBusy && !isError)
                const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: SecureChatColors.turquoise))
              else
                Icon(isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                    color: accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: isError ? SecureChatColors.danger : SecureChatColors.text,
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
              if (isBusy && !isError)
                Text('${(progress * 100).round()}%',
                    style: const TextStyle(color: SecureChatColors.turquoise,
                        fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
            if (isBusy && !isError) ...[
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress, minHeight: 4,
                  backgroundColor: SecureChatColors.border,
                  valueColor: const AlwaysStoppedAnimation<Color>(SecureChatColors.turquoise),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── HEADER ───────────────────────────────────────────────────────────────────

class _ChatHeader extends StatelessWidget {
  final String peerLabel;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onReconnect;
  final VoidCallback onDelete;

  const _ChatHeader({
    required this.peerLabel, required this.statusLabel,
    required this.statusColor, required this.onReconnect, required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final initial = peerLabel.isNotEmpty ? peerLabel.substring(0, 1).toUpperCase() : '?';
    return Container(
      decoration: const BoxDecoration(
        color: SecureChatColors.voidBlack,
        border: Border(bottom: BorderSide(color: SecureChatColors.border, width: 0.5)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              color: SecureChatColors.mutedText,
              onPressed: () => Navigator.of(context).pop(),
            ),
            CircleAvatar(
              radius: 20,
              backgroundColor: SecureChatColors.violet.withValues(alpha: 0.22),
              child: Text(initial,
                  style: const TextStyle(color: SecureChatColors.violetSoft, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(peerLabel, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: SecureChatColors.text, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Row(children: [
                  Container(width: 7, height: 7,
                      decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(statusLabel,
                      style: TextStyle(color: statusColor, fontSize: 11.5, fontWeight: FontWeight.w600)),
                ]),
              ]),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              color: SecureChatColors.mutedText,
              onPressed: onReconnect, tooltip: 'Reconnect',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              color: SecureChatColors.danger.withValues(alpha: 0.75),
              onPressed: onDelete, tooltip: 'Delete conversation',
            ),
          ]),
        ),
      ),
    );
  }
}

// ─── COMPOSER ────────────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const _Composer({required this.controller, required this.isSending,
      required this.onSend, required this.onAttach});

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
            border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
            boxShadow: SecureChatShadows.card,
          ),
          child: Row(children: [
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
                  isDense: true, border: InputBorder.none,
                  enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                ),
                maxLines: null,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            isSending
                ? const SizedBox(width: 42, height: 42,
                    child: Padding(padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : SizedBox(width: 46, height: 46,
                    child: FilledButton(
                      onPressed: onSend,
                      style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero, shape: const CircleBorder(),
                          backgroundColor: SecureChatColors.violet),
                      child: const Icon(Icons.send_rounded, size: 22, color: Colors.white),
                    )),
          ]),
        ),
      ),
    );
  }
}

// ─── EMPTY STATE ─────────────────────────────────────────────────────────────

class _EmptyChat extends StatelessWidget {
  final String peerLabel;
  const _EmptyChat({required this.peerLabel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline_rounded, size: 48, color: SecureChatColors.mutedText),
        const SizedBox(height: 16),
        Text('NIP-44 encrypted conversation with\n$peerLabel',
            textAlign: TextAlign.center,
            style: const TextStyle(color: SecureChatColors.mutedText, fontSize: 15)),
      ]),
    );
  }
}
