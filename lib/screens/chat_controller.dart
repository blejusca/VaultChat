import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/message_model.dart';
import '../services/conversation_storage_service.dart';
import '../services/file_transfer_service.dart';
import '../services/nostr_connection_service.dart';

/// Immutable chat screen state.
class ChatState {
  final List<MessageModel> messages;
  final bool isSending;
  final bool isUploadingAttachment;
  final String? transferStatus;
  final bool transferStatusIsError;
  final bool isConversationClosed;
  final double uploadProgress;
  final SecureChatConnectionSnapshot connectionSnapshot;

  const ChatState({
    required this.messages,
    required this.isSending,
    required this.isUploadingAttachment,
    this.transferStatus,
    required this.transferStatusIsError,
    required this.isConversationClosed,
    required this.uploadProgress,
    required this.connectionSnapshot,
  });

  ChatState copyWith({
    List<MessageModel>? messages,
    bool? isSending,
    bool? isUploadingAttachment,
    String? transferStatus,
    bool clearTransfer = false,
    bool? transferStatusIsError,
    bool? isConversationClosed,
    double? uploadProgress,
    SecureChatConnectionSnapshot? connectionSnapshot,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isSending: isSending ?? this.isSending,
      isUploadingAttachment: isUploadingAttachment ?? this.isUploadingAttachment,
      transferStatus: clearTransfer ? null : (transferStatus ?? this.transferStatus),
      transferStatusIsError: transferStatusIsError ?? this.transferStatusIsError,
      isConversationClosed: isConversationClosed ?? this.isConversationClosed,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      connectionSnapshot: connectionSnapshot ?? this.connectionSnapshot,
    );
  }

  static ChatState initial(SecureChatConnectionSnapshot snapshot) => ChatState(
        messages: const [],
        isSending: false,
        isUploadingAttachment: false,
        transferStatusIsError: false,
        isConversationClosed: false,
        uploadProgress: 0.0,
        connectionSnapshot: snapshot,
      );
}

/// ViewModel for [ChatScreen].
/// Fully separates business logic (send, upload, pagination, subscriptions)
/// from the Flutter widget responsible only for rendering.
class ChatController {
  ChatController({
    required this.recipientPublicKey,
    required this.myPublicKey,
    required this.storageService,
    required this.connectionService,
    required this.onConversationChanged,
    this.onConversationDeleted,
    // Req 9: contacts must be loaded before rendering sender display names.
    this.contactsMap = const {},
  }) : conversationId = MessageModel.buildConversationId(
            myPublicKey, recipientPublicKey) {
    _init();
  }

  final String recipientPublicKey;
  final String myPublicKey;
  final String conversationId;
  final ConversationStorageService storageService;
  final NostrConnectionService connectionService;
  final Future<void> Function() onConversationChanged;
  final Future<void> Function(String peerPublicKey)? onConversationDeleted;
  /// Contact display names keyed by lowercased public key.
  /// Must be populated before constructing this controller (Req 9).
  final Map<String, String> contactsMap;

  // ── Pagination ──────────────────────────────────────────────────────────────
  static const int _pageSize = 50;
  bool _hasMoreMessages = true;
  DateTime? _oldestLoaded;

  // ── In-memory dedup (Reqs 3, 5) ────────────────────────────────────────────
  // Tracks eventIds already in the in-memory list so relay echoes and duplicate
  // deliveries never appear as a second bubble in the UI.
  final Set<String> _seenMessageIds = <String>{};

  // ── State stream ──────────────────────────────────────────────────────────
  final _stateController = StreamController<ChatState>.broadcast();
  Stream<ChatState> get stateStream => _stateController.stream;

  ChatState _state = ChatState.initial(SecureChatConnectionSnapshot(
    state: SecureChatConnectionState.idle,
    label: '',
    updatedAt: DateTime.now(),
  ));
  ChatState get state => _state;

  void _emit(ChatState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  // Req 1: exactly one active relay subscription per conversation.
  StreamSubscription<SecureChatConnectionSnapshot>? _statusSub;
  StreamSubscription<MessageModel>? _messageSub;
  StreamSubscription<RemoteConversationCommand>? _commandSub;

  void _init() {
    _emit(ChatState.initial(connectionService.currentStatus));

    _statusSub = connectionService.statusStream.listen((snap) {
      _emit(_state.copyWith(connectionSnapshot: snap));
    });

    // Req 1 & 2: cancel any prior subscription before subscribing.
    _messageSub?.cancel();
    _messageSub = connectionService.messageStream.listen((msg) async {
      final msgConvId = MessageModel.buildConversationId(
          msg.senderPublicKey, msg.recipientPublicKey);
      if (msgConvId != conversationId) return;

      // Req 3 & 5: deduplicate by eventId before touching memory or UI.
      final msgId = msg.id.trim();
      if (msgId.isEmpty || _seenMessageIds.contains(msgId)) return;

      // Req 9: enrich sender label from contacts before rendering.
      final enriched = _enrichLabel(msg);

      await storageService.saveMessage(enriched);

      // Register id only after the dedup check passes so the message is
      // tracked for future relay echo suppression.
      _seenMessageIds.add(msgId);
      _emit(_state.copyWith(messages: [..._state.messages, enriched]));
      await onConversationChanged();
    });

    // Req 2: cancel stale command subscription.
    _commandSub?.cancel();
    _commandSub = connectionService.commandStream.listen((cmd) {
      if (!cmd.isDeleteConversation) return;
      if (cmd.conversationId != conversationId) return;
      _emit(_state.copyWith(isConversationClosed: true));
    });

    loadInitialMessages();
  }

  /// Resolve sender label from [contactsMap] (Req 9).
  /// Falls back to the label already on the message when no contact entry exists.
  MessageModel _enrichLabel(MessageModel msg) {
    final key = msg.senderPublicKey.trim().toLowerCase();
    final name = contactsMap[key];
    if (name != null && name.isNotEmpty) return msg.copyWith(senderLabel: name);
    return msg;
  }

  // ── Real pagination ────────────────────────────────────────────────────────

  Future<void> loadInitialMessages() async {
    final page = await storageService.loadConversationPage(
      conversationId,
      pageSize: _pageSize,
    );
    if (page.isNotEmpty) {
      _oldestLoaded = page.first.createdAt;
      _hasMoreMessages = page.length >= _pageSize;
    } else {
      _hasMoreMessages = false;
    }
    // Req 3 & 5: seed in-memory dedup set from persisted messages so relay
    // echoes of already-stored messages are never added as duplicates.
    for (final m in page) {
      final id = m.id.trim();
      if (id.isNotEmpty) _seenMessageIds.add(id);
    }
    _emit(_state.copyWith(messages: page));
  }

  /// Called when scrolling up; returns true if messages were loaded.
  Future<bool> loadMoreMessages() async {
    if (!_hasMoreMessages) return false;
    // Track both createdAt and id for the (createdAt, id) pagination cursor
    // so messages with equal timestamps are never split across pages (Req 7).
    final oldestId = _state.messages.isNotEmpty ? _state.messages.first.id : null;
    final page = await storageService.loadConversationPage(
      conversationId,
      pageSize: _pageSize,
      before: _oldestLoaded,
      beforeId: oldestId,
    );
    if (page.isEmpty) {
      _hasMoreMessages = false;
      return false;
    }
    _oldestLoaded = page.first.createdAt;
    _hasMoreMessages = page.length >= _pageSize;
    // Seed newly loaded historical ids into the dedup set.
    for (final m in page) {
      final id = m.id.trim();
      if (id.isNotEmpty) _seenMessageIds.add(id);
    }
    _emit(_state.copyWith(messages: [...page, ..._state.messages]));
    return true;
  }

  bool get hasMoreMessages => _hasMoreMessages;

  // ── Text sending ────────────────────────────────────────────────────────

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_state.isConversationClosed || _state.isSending) return;

    _emit(_state.copyWith(isSending: true));
    try {
      final result = await connectionService.publishDirectMessage(
        recipientPublicKey: recipientPublicKey,
        plainText: trimmed,
      );
      final msg = MessageModel(
        id: result.eventId,
        conversationId: conversationId,
        text: trimmed,
        isMine: true,
        senderLabel: 'Eu',
        senderPublicKey: myPublicKey,
        recipientPublicKey: recipientPublicKey,
        peerPublicKey: recipientPublicKey,
        // Req 6: createdAt = relay-signed Nostr created_at (canonical sort key).
        createdAt: result.createdAt,
        // Req 6: clientCreatedAt = wall-clock compose time, for diagnostics.
        clientCreatedAt: result.clientCreatedAt,
        isFromRelay: false,
      );
      await storageService.saveMessage(msg);
      // Req 4 & 5: register the same eventId used for the local optimistic
      // message so the relay echo is recognised and suppressed.
      _seenMessageIds.add(result.eventId);
      _emit(_state.copyWith(
        isSending: false,
        messages: [..._state.messages, msg],
      ));
      await onConversationChanged();
    } catch (e) {
      _emit(_state.copyWith(isSending: false));
      rethrow;
    }
  }

  // ── Encrypted file upload ─────────────────────────────────────────────────

  Future<void> encryptAndSendBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (_state.isConversationClosed || _state.isUploadingAttachment) return;

    _emit(_state.copyWith(
      isUploadingAttachment: true,
      transferStatus: 'Preparing file...',
      transferStatusIsError: false,
      uploadProgress: 0.05,
    ));

    try {
      final result = await FileTransferService.encryptAndUpload(
        fileBytes: bytes,
        fileName: fileName,
        mimeType: mimeType,
        onProgress: (msg) {
          _emit(_state.copyWith(
            transferStatus: msg,
            uploadProgress: _progressFor(msg),
          ));
        },
      );

      _emit(_state.copyWith(
          transferStatus: 'Finalizing transfer...', uploadProgress: 0.92));

      final meta = AttachmentMeta(
        url: result.remoteUrl,
        encKey: result.encKeyHex,
        encIv: result.encIvHex,
        encTag: result.encTagHex,
        fileName: fileName,
        mimeType: mimeType,
        fileSize: bytes.length,
        blobSha256: result.blobSha256,
      );

      final metaJson = jsonEncode(meta.toJson());
      final sendResult = await connectionService.publishDirectMessage(
        recipientPublicKey: recipientPublicKey,
        plainText: metaJson,
      );

      final msg = MessageModel(
        id: sendResult.eventId,
        conversationId: conversationId,
        text: metaJson,
        isMine: true,
        senderLabel: 'Eu',
        senderPublicKey: myPublicKey,
        recipientPublicKey: recipientPublicKey,
        peerPublicKey: recipientPublicKey,
        createdAt: sendResult.createdAt,
        clientCreatedAt: sendResult.clientCreatedAt,
        isFromRelay: false,
      );

      await storageService.saveMessage(msg);
      // Req 4 & 5: register the eventId so the relay echo is suppressed.
      _seenMessageIds.add(sendResult.eventId);
      _emit(_state.copyWith(
        isUploadingAttachment: false,
        transferStatus: 'File sent.',
        uploadProgress: 1.0,
        transferStatusIsError: false,
        messages: [..._state.messages, msg],
      ));
      await onConversationChanged();

      await Future<void>.delayed(const Duration(seconds: 3));
      _emit(_state.copyWith(clearTransfer: true, uploadProgress: 0.0));
    } catch (e) {
      _emit(_state.copyWith(
        transferStatus: 'Upload error: $e',
        transferStatusIsError: true,
        isUploadingAttachment: false,
        uploadProgress: 0.0,
      ));
    }
  }

  // ── Picker helpers ────────────────────────────────────────────────────────

  Future<void> sendFromCamera() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.camera, imageQuality: 85, maxWidth: 1920);
    if (picked == null) return;
    await encryptAndSendBytes(
        bytes: await picked.readAsBytes(),
        fileName: picked.name,
        mimeType: 'image/jpeg');
  }

  Future<void> sendFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80, maxWidth: 1920);
    if (picked == null) return;
    final mime = picked.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    await encryptAndSendBytes(
        bytes: await picked.readAsBytes(), fileName: picked.name, mimeType: mime);
  }

  Future<void> pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    await encryptAndSendBytes(
        bytes: bytes,
        fileName: file.name,
        mimeType: 'application/octet-stream');
  }

  // ── Deletere ──────────────────────────────────────────────────────────────

  Future<void> deleteConversation() async {
    try {
      await connectionService.publishDeleteConversationCommand(
        recipientPublicKey: recipientPublicKey,
        conversationId: conversationId,
      );
    } catch (_) {}
    await storageService.deleteConversationCompletely(conversationId);
    await onConversationDeleted?.call(recipientPublicKey);
  }

  // ── Helper progress ───────────────────────────────────────────────────────

  static double _progressFor(String text) {
    final t = text.toLowerCase();
    if (t.contains('preparing') || t.contains('pregateste')) return 0.10;
    if (t.contains('encrypting') || t.contains('cripteaza')) return 0.30;
    if (t.contains('uploading') || t.contains('upload')) return 0.60;
    if (t.contains('verifying') || t.contains('verifica')) return 0.85;
    if (t.contains('finalizing') || t.contains('finalizeaza')) return 0.95;
    return 0.50;
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await _statusSub?.cancel();
    await _messageSub?.cancel();
    await _commandSub?.cancel();
    await _stateController.close();
  }
}
