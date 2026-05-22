import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message_model.dart';
import '../services/conversation_storage_service.dart';
import '../services/nostr_connection_service.dart';
import '../theme/secure_chat_theme.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  final String recipientPublicKey;
  final String myPublicKey;
  final String peerLabel;
  final ConversationStorageService storageService;
  final NostrConnectionService connectionService;
  final Future<void> Function() onConversationChanged;
  final Future<void> Function(String peerPublicKey)? onConversationDeleted;

  const ChatScreen({
    super.key,
    required this.recipientPublicKey,
    required this.myPublicKey,
    required this.peerLabel,
    required this.storageService,
    required this.connectionService,
    required this.onConversationChanged,
    this.onConversationDeleted,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<MessageModel> _messages = [];
  bool _isSending = false;
  bool _isConversationClosed = false;
  late String _conversationId;

  late SecureChatConnectionSnapshot _connectionSnapshot;

  StreamSubscription<SecureChatConnectionSnapshot>? _statusSub;
  StreamSubscription<MessageModel>? _messageSub;
  StreamSubscription<RemoteConversationCommand>? _commandSub;

  @override
  void initState() {
    super.initState();

    _conversationId = MessageModel.buildConversationId(
      widget.myPublicKey,
      widget.recipientPublicKey,
    );

    // FIX 1: init from currentStatus so it never shows "Deconectat" incorrectly
    _connectionSnapshot = widget.connectionService.currentStatus;

    _loadMessages();

    // Status updates
    _statusSub = widget.connectionService.statusStream.listen((snap) {
      if (!mounted) return;
      setState(() => _connectionSnapshot = snap);
    });

    // FIX 2: listen for incoming messages while screen is open
    _messageSub = widget.connectionService.messageStream.listen((msg) async {
      if (msg.conversationId != _conversationId) return;
      await widget.storageService.saveMessage(msg);
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == msg.id);
        if (idx >= 0) {
          _messages[idx] = msg;
        } else {
          _messages = [..._messages, msg];
        }
      });
      _scrollToBottom();
      await widget.onConversationChanged();
    });

    // FIX 3: listen for remote delete command
    _commandSub = widget.connectionService.commandStream.listen((command) async {
      if (!command.isDeleteConversation) return;
      if (command.conversationId != _conversationId) return;

      await widget.storageService.deleteConversationCompletely(
        _conversationId,
        deletedAt: command.createdAt,
      );

      if (!mounted) return;
      setState(() => _isConversationClosed = true);
      await widget.onConversationChanged();
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _messageSub?.cancel();
    _commandSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    final msgs = await widget.storageService.loadConversation(_conversationId);
    if (!mounted) return;
    setState(() => _messages = msgs);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    if (_isConversationClosed || _isSending) return;
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isSending = true);
    _messageController.clear();

    try {
      final result = await widget.connectionService.publishDirectMessage(
        recipientPublicKey: widget.recipientPublicKey,
        plainText: text,
      );

      final outgoing = MessageModel(
        id: result.eventId,
        conversationId: _conversationId,
        text: text,
        isMine: true,
        senderLabel: 'Eu',
        senderPublicKey: widget.myPublicKey,
        recipientPublicKey: widget.recipientPublicKey,
        peerPublicKey: widget.recipientPublicKey,
        createdAt: result.createdAt,
        isFromRelay: false,
      );

      // Save first, then update UI - prevents race condition where
      // onConversationChanged triggers a reload before save completes.
      await widget.storageService.saveMessage(outgoing);

      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == outgoing.id);
        if (idx >= 0) {
          _messages[idx] = outgoing;
        } else {
          _messages = [..._messages, outgoing];
        }
      });
      _scrollToBottom();

      // Notify inbox AFTER UI is updated
      await widget.onConversationChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Eroare la trimitere: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _confirmDeleteConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        backgroundColor: SecureChatColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.xl),
        ),
        icon: const Icon(Icons.delete_outline_rounded,
            color: SecureChatColors.danger),
        title: const Text(
          'Ștergi conversația?',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: SecureChatColors.text, fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Conversația și toate mesajele vor fi șterse '
          'de pe ambele telefoane simultan.\n\n'
          'Acțiunea este ireversibilă.',
          textAlign: TextAlign.center,
          style: TextStyle(color: SecureChatColors.mutedText, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anulează'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: SecureChatColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Șterge'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _isConversationClosed = true);

    await widget.connectionService.publishDeleteConversationCommand(
      recipientPublicKey: widget.recipientPublicKey,
      conversationId: _conversationId,
    );
    await widget.storageService.deleteConversationCompletely(
      _conversationId,
      deletedAt: DateTime.now(),
    );

    if (!mounted) return;
    await widget.onConversationDeleted?.call(widget.recipientPublicKey);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected =
        _connectionSnapshot.state == SecureChatConnectionState.connected;
    final isConnecting =
        _connectionSnapshot.state == SecureChatConnectionState.connecting ||
            _connectionSnapshot.state == SecureChatConnectionState.reconnecting;

    final statusLabel = isConnected
        ? 'Conectat'
        : isConnecting
            ? 'Se conectează...'
            : 'Deconectat';

    final statusColor = isConnected
        ? SecureChatColors.turquoise
        : isConnecting
            ? SecureChatColors.warning
            : SecureChatColors.danger;

    return Scaffold(
      backgroundColor: SecureChatColors.deepNavy,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _ChatHeader(
              peerLabel: widget.peerLabel,
              statusLabel: statusLabel,
              statusColor: statusColor,
              onReconnect: () =>
                  widget.connectionService.refreshIfNeeded(reason: 'Manual'),
              onDelete: _confirmDeleteConversation,
            ),
            Expanded(
              child: _messages.isEmpty
                  ? _EmptyChat(peerLabel: widget.peerLabel)
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) =>
                          MessageBubble(message: _messages[i]),
                    ),
            ),
            _Composer(
              controller: _messageController,
              isSending: _isSending,
              onSend: _sendMessage,
            ),
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
            tooltip: 'Reconectează',
            onPressed: onReconnect,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            color: SecureChatColors.danger,
            tooltip: 'Șterge conversația',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

// ─── COMPOSER ────────────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 13),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(
            color: SecureChatColors.card.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(SecureChatRadius.xxl),
            border: Border.all(
                color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
            boxShadow: SecureChatShadows.card,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  style: const TextStyle(color: SecureChatColors.text),
                  decoration: const InputDecoration(
                    hintText: 'Scrie un mesaj...',
                    hintStyle:
                        TextStyle(color: SecureChatColors.mutedText),
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

// ─── EMPTY STATE ─────────────────────────────────────────────────────────────

class _EmptyChat extends StatelessWidget {
  final String peerLabel;
  const _EmptyChat({required this.peerLabel});

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
            'Conversație criptată cu\n$peerLabel',
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
