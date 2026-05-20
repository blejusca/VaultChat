import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message_model.dart';
import '../services/conversation_storage_service.dart';
import '../services/nostr_connection_service.dart';
import '../theme/secure_chat_theme.dart';
import '../widgets/message_bubble.dart';

// Optiunile de autodistrugere
enum TtlOption {
  never,
  oneHour,
  twelveHours,
  oneDay,
  sevenDays,
  thirtyDays,
}

extension TtlOptionExtension on TtlOption {
  String get label {
    switch (this) {
      case TtlOption.never:       return 'Niciodată';
      case TtlOption.oneHour:     return '1 oră';
      case TtlOption.twelveHours: return '12 ore';
      case TtlOption.oneDay:      return '24 ore';
      case TtlOption.sevenDays:   return '7 zile';
      case TtlOption.thirtyDays:  return '30 zile';
    }
  }

  Duration? get duration {
    switch (this) {
      case TtlOption.never:       return null;
      case TtlOption.oneHour:     return const Duration(hours: 1);
      case TtlOption.twelveHours: return const Duration(hours: 12);
      case TtlOption.oneDay:      return const Duration(hours: 24);
      case TtlOption.sevenDays:   return const Duration(days: 7);
      case TtlOption.thirtyDays:  return const Duration(days: 30);
    }
  }

  // Cheia pentru SharedPreferences
  String get prefKey => 'ttl_${name}';
}

class ChatScreen extends StatefulWidget {
  final String myPublicKey;
  final String recipientPublicKey;
  final ConversationStorageService storageService;
  final NostrConnectionService connectionService;
  final String? contactLabel;
  final Future<void> Function() onConversationChanged;
  final Future<void> Function(String peerPublicKey)? onConversationDeleted;

  const ChatScreen({
    super.key,
    required this.myPublicKey,
    required this.recipientPublicKey,
    required this.storageService,
    required this.connectionService,
    this.contactLabel,
    required this.onConversationChanged,
    this.onConversationDeleted,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _listScrollController = ScrollController();

  final List<MessageModel> _messages = <MessageModel>[];

  StreamSubscription<MessageModel>? _messageSubscription;
  StreamSubscription<RemoteConversationCommand>? _commandSubscription;
  StreamSubscription<SecureChatConnectionSnapshot>? _statusSubscription;
  Timer? _expiryTimer;
  Timer? _nextExpiryTimer;

  bool _isLoading = true;
  bool _isSending = false;
  bool _isConversationClosed = false;

  // TTL selectat pentru aceasta conversatie
  TtlOption _selectedTtl = TtlOption.never;

  // Cheia SharedPreferences pentru TTL-ul acestei conversatii
  late String _ttlPrefKey;

  late SecureChatConnectionSnapshot _connectionSnapshot;
  late String _conversationId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _conversationId = MessageModel.buildConversationId(
      widget.myPublicKey,
      widget.recipientPublicKey,
    );

    _ttlPrefKey = 'ttl_conv_$_conversationId';

    _connectionSnapshot = widget.connectionService.currentStatus;

    _statusSubscription = widget.connectionService.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _connectionSnapshot = status);
    });

    _messageSubscription = widget.connectionService.messageStream.listen(
      _handleIncomingMessage,
    );

    _commandSubscription = widget.connectionService.commandStream.listen(
      _handleRemoteCommand,
    );

    _loadTtlPreference();
    _purgeExpiredMessages();
    _loadMessages();
    _startExpiryTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        widget.connectionService.reconnect(
          reason: 'Revenire in chat',
          force: true,
        ),
      );
      unawaited(_purgeExpiredMessages());
      unawaited(_loadMessages());
    }
  }

  // ─── TTL ──────────────────────────────────────────────────────────────────

  Future<void> _loadTtlPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_ttlPrefKey);
    if (!mounted) return;
    if (mounted) setState(() {
      _selectedTtl = TtlOption.values.firstWhere(
        (o) => o.name == saved,
        orElse: () => TtlOption.never,
      );
    });
  }

  Future<void> _saveTtlPreference(TtlOption option) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ttlPrefKey, option.name);
  }

  void _startExpiryTimer() {
    _expiryTimer?.cancel();
    _nextExpiryTimer?.cancel();

    // Fallback global pentru cazul in care telefonul suspenda timer-ul punctual.
    _expiryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_purgeExpiredMessages());
    });

    unawaited(_scheduleNextExpiryTick());
  }

  Future<void> _scheduleNextExpiryTick() async {
    _nextExpiryTimer?.cancel();
    if (_isConversationClosed) return;

    final nextExpiry =
        await widget.storageService.nextExpiryTimeForConversation(_conversationId);
    if (!mounted || _isConversationClosed || nextExpiry == null) return;

    final delay = nextExpiry.difference(DateTime.now());
    final safeDelay = delay.isNegative
        ? const Duration(milliseconds: 150)
        : delay + const Duration(milliseconds: 300);

    _nextExpiryTimer = Timer(safeDelay, () {
      unawaited(_purgeExpiredMessages());
    });
  }

  Future<void> _purgeExpiredMessages() async {
    if (_isConversationClosed) return;

    final deleted = await widget.storageService.deleteExpiredMessages();
    if (!mounted || _isConversationClosed) return;

    if (deleted > 0) {
      await _loadMessages();
      await widget.onConversationChanged();
    }

    await _scheduleNextExpiryTick();
  }

  void _showTtlPicker() {
    showModalBottomSheet<TtlOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SecureChatColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SecureChatRadius.xl),
        ),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: SecureChatColors.borderSoft,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    Icon(Icons.timer_outlined, color: SecureChatColors.violetSoft, size: 22),
                    SizedBox(width: 10),
                    Text(
                      'Autodistrugere mesaje',
                      style: TextStyle(
                        color: SecureChatColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Mesajele se vor sterge local dupa intervalul ales.',
                  style: TextStyle(
                    color: SecureChatColors.mutedText,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 14),
                ...TtlOption.values.map((option) {
                  final isSelected = option == _selectedTtl;
                  return InkWell(
                    borderRadius: BorderRadius.circular(SecureChatRadius.md),
                    onTap: () => Navigator.pop(ctx, option),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? SecureChatColors.violet.withValues(alpha: 0.18)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(SecureChatRadius.md),
                        border: Border.all(
                          color: isSelected
                              ? SecureChatColors.violet.withValues(alpha: 0.55)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            option == TtlOption.never
                                ? Icons.timer_off_outlined
                                : Icons.timer_outlined,
                            color: isSelected
                                ? SecureChatColors.violetBright
                                : SecureChatColors.mutedText,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            option.label,
                            style: TextStyle(
                              color: isSelected
                                  ? SecureChatColors.violetBright
                                  : SecureChatColors.text,
                              fontSize: 15,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                            ),
                          ),
                          const Spacer(),
                          if (isSelected)
                            const Icon(
                              Icons.check_rounded,
                              color: SecureChatColors.violetBright,
                              size: 20,
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 10),
                Divider(
                  height: 24,
                  color: SecureChatColors.borderSoft.withValues(alpha: 0.65),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(SecureChatRadius.md),
                  onTap: () {
                    Navigator.pop(ctx);
                    Future.microtask(_confirmDeleteAllMessages);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(SecureChatRadius.md),
                      border: Border.all(
                        color: SecureChatColors.danger.withValues(alpha: 0.42),
                      ),
                      color: SecureChatColors.danger.withValues(alpha: 0.08),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          color: SecureChatColors.danger,
                          size: 21,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Șterge toate mesajele acum',
                            style: TextStyle(
                              color: SecureChatColors.danger,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ).then((chosen) async {
      if (chosen == null || !mounted) return;
      setState(() => _selectedTtl = chosen);
      await _saveTtlPreference(chosen);
      await _scheduleNextExpiryTick();

      final label = chosen == TtlOption.never
          ? 'Autodistrugere dezactivata.'
          : 'Mesajele noi se vor sterge dupa ${chosen.label}.';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(label),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }


  Future<void> _confirmDeleteAllMessages() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        backgroundColor: SecureChatColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SecureChatRadius.xl),
        ),
        title: const Text(
          'Șterge toate mesajele?',
          style: TextStyle(
            color: SecureChatColors.text,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: const Text(
          'Ești sigur că vrei să ștergi toate mesajele din această conversație?\n\n'
          'Acțiunea este ireversibilă.',
          style: TextStyle(
            color: SecureChatColors.mutedText,
            height: 1.35,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Anulează'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SecureChatColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Șterge tot'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await widget.connectionService.publishDeleteConversationCommand(
        recipientPublicKey: widget.recipientPublicKey,
        conversationId: _conversationId,
      );
    } catch (_) {
      // Daca nu se poate trimite comanda remote, continuam stergerea locala.
      // Utilizatorul poate incerca din nou dupa reconnect.
    }

    final deleted = await widget.storageService.deleteConversationCompletely(
      _conversationId,
    );

    await _closeDeletedConversation(
      snackMessage: deleted == 0
          ? 'Conversația a fost ștearsă.'
          : 'Conversația a fost ștearsă complet.',
      isRemoteDelete: false,
    );
  }

  Future<void> _closeDeletedConversation({
    required String snackMessage,
    required bool isRemoteDelete,
  }) async {
    if (_isConversationClosed) return;
    _isConversationClosed = true;

    _expiryTimer?.cancel();
    _nextExpiryTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ttlPrefKey);
    await _messageSubscription?.cancel();
    await _commandSubscription?.cancel();

    if (mounted) {
      setState(() {
        _messages.clear();
        _messageController.clear();
        _isSending = false;
      });
    }

    await widget.onConversationDeleted?.call(widget.recipientPublicKey);
    await widget.onConversationChanged();

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    navigator.pop();

    messenger.showSnackBar(
      SnackBar(
        content: Text(snackMessage),
        backgroundColor: isRemoteDelete ? null : SecureChatColors.danger,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ─── Mesaje ────────────────────────────────────────────────────────────────

  Future<void> _loadMessages() async {
    if (_isConversationClosed) return;
    final messages = await widget.storageService.loadConversation(_conversationId);

    if (!mounted || _isConversationClosed) return;

    if (mounted) setState(() {
      _messages
        ..clear()
        ..addAll(_deduplicateAndSort(messages));
      _isLoading = false;
    });

    _scrollToBottom();
  }

  Future<void> _handleIncomingMessage(MessageModel message) async {
    if (message.conversationId.trim().toLowerCase() !=
        _conversationId.trim().toLowerCase()) {
      return;
    }

    // Important: si UI-ul trebuie sa respecte tombstone-ul local.
    // Altfel mesajele vechi replay-uite de relay pot reaparea vizual,
    // chiar daca storage-ul refuza sa le mai salveze.
    if (!widget.storageService.shouldAcceptMessage(message)) return;

    if (!mounted) return;
    setState(() => _insertOrReplaceMessage(message));
    await _scheduleNextExpiryTick();
    _scrollToBottom();
  }

  Future<void> _handleRemoteCommand(RemoteConversationCommand command) async {
    if (!command.isDeleteConversation) return;
    if (command.conversationId.trim().toLowerCase() !=
        _conversationId.trim().toLowerCase()) {
      return;
    }

    await widget.storageService.deleteConversationCompletely(
      _conversationId,
      deletedAt: command.createdAt,
    );

    await _closeDeletedConversation(
      snackMessage: 'Conversația a fost ștearsă de celălalt utilizator.',
      isRemoteDelete: true,
    );
  }

  Future<void> _sendMessage() async {
    if (_isConversationClosed) return;
    if (_isSending) return;

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    if (!mounted) return;
    setState(() => _isSending = true);

    try {
      final duration = _selectedTtl.duration;
      final result = await widget.connectionService.publishDirectMessage(
        recipientPublicKey: widget.recipientPublicKey,
        plainText: text,
        ttlSeconds: duration?.inSeconds,
      );

      // Calculeaza expiresAt bazat pe TTL selectat si il sincronizeaza cu payload-ul criptat.
      final expiresAt = duration != null ? result.createdAt.add(duration) : null;

      final outgoingMessage = MessageModel(
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
        expiresAt: expiresAt,
      );

      await widget.storageService.saveMessage(outgoingMessage);
      await widget.onConversationChanged();
      await _scheduleNextExpiryTick();

      if (!mounted) return;

      if (mounted) setState(() {
        _insertOrReplaceMessage(outgoingMessage);
        _messageController.clear();
      });

      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Trimitere esuata: $e'),
          backgroundColor: SecureChatColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _insertOrReplaceMessage(MessageModel message) {
    final index = _messages.indexWhere((item) => item.id == message.id);

    if (index >= 0) {
      _messages[index] = message;
    } else {
      _messages.add(message);
    }

    _messages
      ..removeWhere((item) => item.id.trim().isEmpty)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
  }

  List<MessageModel> _deduplicateAndSort(List<MessageModel> source) {
    final byId = <String, MessageModel>{};

    for (final message in source) {
      if (message.id.trim().isEmpty) continue;
      byId[message.id] = message;
    }

    final result = byId.values.toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });

    return result;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_listScrollController.hasClients) return;
      _listScrollController.animateTo(
        _listScrollController.position.maxScrollExtent,
        duration: SecureChatMotion.normal,
        curve: SecureChatMotion.curve,
      );
    });
  }

  Color _statusColor() {
    switch (_connectionSnapshot.state) {
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

  String get _peerLabel {
    final label = widget.contactLabel?.trim();
    if (label != null && label.isNotEmpty) return label;
    return 'Contact necunoscut';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSubscription?.cancel();
    _commandSubscription?.cancel();
    _statusSubscription?.cancel();
    _expiryTimer?.cancel();
    _nextExpiryTimer?.cancel();
    _messageController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [SecureChatColors.voidBlack, SecureChatColors.deepNavy, Color(0xFF11162A)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _ChatHeader(
                peerLabel: _peerLabel,
                connectionLabel: _connectionSnapshot.label,
                statusColor: _statusColor(),
                selectedTtl: _selectedTtl,
                onReconnect: () => widget.connectionService.reconnect(
                  reason: 'Manual',
                  force: true,
                ),
                onTtlTap: _showTtlPicker,
              ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                        ? _EmptyChat(peerLabel: _peerLabel)
                        : ListView.builder(
                            controller: _listScrollController,
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                            itemCount: _messages.length + 1,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return _EncryptedNotice(ttl: _selectedTtl);
                              }
                              final message = _messages[index - 1];
                              final displayMessage = !message.isMine
                                  ? message.copyWith(senderLabel: _peerLabel)
                                  : message;
                              return MessageBubble(message: displayMessage);
                            },
                          ),
              ),
              _Composer(
                controller: _messageController,
                isSending: _isSending,
                selectedTtl: _selectedTtl,
                onSend: _isConversationClosed ? () {} : _sendMessage,
                onTtlTap: _showTtlPicker,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── HEADER ──────────────────────────────────────────────────────────────────

class _ChatHeader extends StatelessWidget {
  final String peerLabel;
  final String connectionLabel;
  final Color statusColor;
  final TtlOption selectedTtl;
  final VoidCallback onReconnect;
  final VoidCallback onTtlTap;

  const _ChatHeader({
    required this.peerLabel,
    required this.connectionLabel,
    required this.statusColor,
    required this.selectedTtl,
    required this.onReconnect,
    required this.onTtlTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [SecureChatColors.violet, SecureChatColors.turquoise],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                peerLabel.isNotEmpty ? peerLabel.substring(0, 1).toUpperCase() : '?',
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
                    Flexible(
                      child: Text(
                        connectionLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Buton TTL in header
          IconButton(
            icon: Icon(
              selectedTtl == TtlOption.never
                  ? Icons.timer_off_outlined
                  : Icons.timer_outlined,
              color: selectedTtl == TtlOption.never
                  ? SecureChatColors.mutedText
                  : SecureChatColors.violetBright,
            ),
            tooltip: 'Autodistrugere: ${selectedTtl.label}',
            onPressed: onTtlTap,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Reconecteaza manual',
            onPressed: onReconnect,
          ),
        ],
      ),
    );
  }
}

// ─── NOTICE CRIPTARE + TTL ────────────────────────────────────────────────────

class _EncryptedNotice extends StatelessWidget {
  final TtlOption ttl;
  const _EncryptedNotice({required this.ttl});

  @override
  Widget build(BuildContext context) {
    final hasTtl = ttl != TtlOption.never;

    return Center(
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: SecureChatColors.cardAlt.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(SecureChatRadius.md),
          border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 17, color: SecureChatColors.turquoise),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text(
                    'Mesajele sunt criptate end-to-end.',
                    style: TextStyle(color: SecureChatColors.mutedText, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            if (hasTtl) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer_outlined, size: 15, color: SecureChatColors.violetSoft),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Autodistrugere activă: ${ttl.label}',
                      style: const TextStyle(
                        color: SecureChatColors.violetSoft,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── COMPOSER ────────────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool isSending;
  final TtlOption selectedTtl;
  final VoidCallback onSend;
  final VoidCallback onTtlTap;

  const _Composer({
    required this.controller,
    required this.isSending,
    required this.selectedTtl,
    required this.onSend,
    required this.onTtlTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasTtl = selectedTtl != TtlOption.never;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 13),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            color: SecureChatColors.card.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(SecureChatRadius.xxl),
            border: Border.all(color: SecureChatColors.borderSoft.withValues(alpha: 0.62)),
            boxShadow: SecureChatShadows.card,
          ),
          child: Row(
            children: [
              // Buton timer
              GestureDetector(
                onTap: onTtlTap,
                child: Tooltip(
                  message: 'Autodistrugere: ${selectedTtl.label}',
                  child: Icon(
                    hasTtl ? Icons.timer_outlined : Icons.timer_off_outlined,
                    color: hasTtl
                        ? SecureChatColors.violetBright
                        : SecureChatColors.turquoise,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  style: const TextStyle(color: SecureChatColors.text),
                  decoration: const InputDecoration(
                    hintText: 'Scrie un mesaj...',
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
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
                        ),
                        child: const Icon(Icons.send_rounded, size: 22),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── EMPTY CHAT ───────────────────────────────────────────────────────────────

class _EmptyChat extends StatelessWidget {
  final String peerLabel;

  const _EmptyChat({required this.peerLabel});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 430),
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                decoration: BoxDecoration(
                  color: SecureChatColors.cardAlt.withValues(alpha: 0.76),
                  borderRadius: BorderRadius.circular(SecureChatRadius.xl),
                  border: Border.all(
                    color: SecureChatColors.borderSoft.withValues(alpha: 0.62),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.lock_outline_rounded,
                      size: 40,
                      color: SecureChatColors.violetBright,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Conversație criptată cu $peerLabel',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: SecureChatColors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Mesajele sunt salvate local pe acest telefon.',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: SecureChatColors.mutedText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
