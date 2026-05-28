import 'package:hive_flutter/hive_flutter.dart';

import 'secure_hive_service.dart';

import '../models/conversation_model.dart';
import '../models/message_model.dart';
import 'file_transfer_service.dart';

/// Returns a human-readable inbox preview for [text].
/// If the text is a vault attachment JSON payload, it returns
/// an emoji label based on the attachment type instead of raw JSON.
String _previewText(String text) {
  final meta = AttachmentMeta.tryFromMessageText(text);
  if (meta == null) return text;
  switch (meta.type) {
    case AttachmentType.image:
      return '📎 Image';
    case AttachmentType.pdf:
      return '📎 PDF';
    case AttachmentType.unknown:
      return '📎 File';
  }
}

class ConversationStorageService {
  ConversationStorageService._({
    required Box messagesBox,
    required Box conversationsBox,
    required Box deletedConversationsBox,
  })  : _messagesBox = messagesBox,
        _conversationsBox = conversationsBox,
        _deletedConversationsBox = deletedConversationsBox;

  static const String _messagesBoxName = 'secure_chat_messages_v4_encrypted';
  static const String _conversationsBoxName = 'secure_chat_conversations_v4_encrypted';
  static const String _deletedConversationsBoxName =
      'secure_chat_deleted_conversations_v2_encrypted';

  final Box _messagesBox;
  final Box _conversationsBox;
  final Box _deletedConversationsBox;

  static const String unknownContactLabel = 'Unknown contact';

  bool _looksLikeTechnicalLabel(String value, String peerPublicKey) {
    final clean = value.trim().toLowerCase();
    final peer = _normalizePublicKey(peerPublicKey);
    if (clean.isEmpty) return true;
    if (clean == unknownContactLabel.toLowerCase()) return true;
    if (clean == 'eu') return true;
    if (clean == peer) return true;
    if (peer.length >= 8 && clean == peer.substring(0, 8)) return true;
    if (RegExp(r'^[0-9a-f]{8}$').hasMatch(clean)) return true;
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(clean)) return true;
    return false;
  }

  String _cleanPeerLabel({
    required String? proposed,
    required String? existing,
    required String peerPublicKey,
  }) {
    final existingClean = existing?.trim() ?? '';
    if (existingClean.isNotEmpty &&
        !_looksLikeTechnicalLabel(existingClean, peerPublicKey)) {
      return existingClean;
    }

    final proposedClean = proposed?.trim() ?? '';
    if (proposedClean.isNotEmpty &&
        !_looksLikeTechnicalLabel(proposedClean, peerPublicKey)) {
      return proposedClean;
    }

    final peer = _normalizePublicKey(peerPublicKey);
    if (peer.length >= 8) return peer.substring(0, 8);
    return unknownContactLabel;
  }

  static Future<void> deleteAllLocalData() async {
    await Hive.initFlutter();

    if (Hive.isBoxOpen(_messagesBoxName)) {
      await Hive.box(_messagesBoxName).close();
    }
    if (Hive.isBoxOpen(_conversationsBoxName)) {
      await Hive.box(_conversationsBoxName).close();
    }
    if (Hive.isBoxOpen(_deletedConversationsBoxName)) {
      await Hive.box(_deletedConversationsBoxName).close();
    }

    try {
      await Hive.deleteBoxFromDisk(_messagesBoxName);
    } catch (_) {}
    try {
      await Hive.deleteBoxFromDisk(_conversationsBoxName);
    } catch (_) {}
    try {
      await Hive.deleteBoxFromDisk(_deletedConversationsBoxName);
    } catch (_) {}

    for (final legacyName in const <String>[
      'secure_chat_messages_v3',
      'secure_chat_conversations_v3',
      'secure_chat_deleted_conversations_v1',
    ]) {
      try {
        if (Hive.isBoxOpen(legacyName)) await Hive.box(legacyName).close();
        await Hive.deleteBoxFromDisk(legacyName);
      } catch (_) {}
    }
  }

  static Future<ConversationStorageService> open() async {
    await Hive.initFlutter();
    final messagesBox = await SecureHiveService.openEncryptedBox(_messagesBoxName);
    final conversationsBox =
        await SecureHiveService.openEncryptedBox(_conversationsBoxName);
    final deletedConversationsBox =
        await SecureHiveService.openEncryptedBox(_deletedConversationsBoxName);

    final service = ConversationStorageService._(
      messagesBox: messagesBox,
      conversationsBox: conversationsBox,
      deletedConversationsBox: deletedConversationsBox,
    );

    await service.sanitizeStorage();
    return service;
  }

  String _normalizeConversationId(String conversationId) {
    return conversationId.trim().toLowerCase();
  }

  String _normalizePublicKey(String publicKey) {
    return publicKey.trim().toLowerCase();
  }

  bool _looksLikePublicKey(String value) {
    final clean = _normalizePublicKey(value);
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(clean);
  }

  String _canonicalConversationId(String myPublicKey, String peerPublicKey) {
    final myKey = _normalizePublicKey(myPublicKey);
    final peerKey = _normalizePublicKey(peerPublicKey);
    if (!_looksLikePublicKey(myKey) || !_looksLikePublicKey(peerKey)) return '';
    if (myKey == peerKey) return '';
    return _normalizeConversationId(MessageModel.buildConversationId(myKey, peerKey));
  }

  String _canonicalConversationIdFromMessage(MessageModel message) {
    return _canonicalConversationId(
      message.senderPublicKey,
      message.recipientPublicKey,
    );
  }

  DateTime? _deletedAtForConversation(String conversationId) {
    final key = _normalizeConversationId(conversationId);
    if (key.isEmpty) return null;
    final raw = _deletedConversationsBox.get(key);
    if (raw == null) return null;
    final millis = raw is int ? raw : int.tryParse('$raw');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> _markConversationDeleted(
    String conversationId,
    DateTime deletedAt,
  ) async {
    final key = _normalizeConversationId(conversationId);
    if (key.isEmpty) return;

    final existing = _deletedAtForConversation(key);
    if (existing == null || deletedAt.isAfter(existing)) {
      await _deletedConversationsBox.put(key, deletedAt.millisecondsSinceEpoch);
    }
  }

  bool _isBlockedByTombstone(String conversationId, DateTime messageTime) {
    final deletedAt = _deletedAtForConversation(conversationId);
    if (deletedAt == null) return false;
    return !messageTime.isAfter(deletedAt);
  }



  bool shouldAcceptMessage(MessageModel message) {
    if (message.id.trim().isEmpty) return false;
    if (message.conversationId.trim().isEmpty) return false;
    if (message.isExpired) return false;
    return !_isBlockedByTombstone(message.conversationId, message.createdAt);
  }


  Future<void> ensureConversationExists({
    required String myPublicKey,
    required String peerPublicKey,
    String? peerLabel,
  }) async {
    final cleanMyKey = _normalizePublicKey(myPublicKey);
    final cleanPeerKey = _normalizePublicKey(peerPublicKey);
    final conversationId = _canonicalConversationId(cleanMyKey, cleanPeerKey);
    if (conversationId.isEmpty) return;

    // The conversation was explicitly recreated by the user.
    // Remove the tombstone to prevent ghost-thread state
    // and allow clean reconstruction of the new conversation.
    await _deletedConversationsBox.delete(conversationId);

    final existingRaw = _conversationsBox.get(conversationId);
    final existing = existingRaw is Map
        ? ConversationModel.fromMap(existingRaw)
        : null;

    final effectiveLabel = _cleanPeerLabel(
      proposed: peerLabel,
      existing: existing?.peerLabel,
      peerPublicKey: cleanPeerKey,
    );

    final conversation = ConversationModel(
      id: conversationId,
      myPublicKey: cleanMyKey,
      peerPublicKey: cleanPeerKey,
      peerLabel: effectiveLabel,
      lastMessageText: existing?.lastMessageText ?? '',
      updatedAt: existing?.updatedAt ?? DateTime.now(),
      unreadCount: existing?.unreadCount ?? 0,
    );

    // A single canonical entry per key pair. Any old/non-canonical key
    // este eliminata in sanitizeStorage().
    await _conversationsBox.put(conversationId, conversation.toMap());
  }

  Future<void> saveMessage(MessageModel message) async {
    if (message.id.trim().isEmpty) return;
    if (message.conversationId.trim().isEmpty) return;
    var cleanMessage = message;
    final canonicalId = _canonicalConversationIdFromMessage(message);
    if (canonicalId.isEmpty) return;
    if (_normalizeConversationId(message.conversationId) != canonicalId) {
      cleanMessage = message.copyWith(conversationId: canonicalId);
    }
    if (!shouldAcceptMessage(cleanMessage)) return;

    // DEFENSIVE FIX: prevent relay replay from overwriting a locally sent
    // message (isMine:true) with a replayed incoming version (isMine:false).
    // This happens when the relay re-delivers an event the user sent, and the
    // incoming relay copy arrives with isMine:false after app restart but
    // before _seenIncomingEventIds is repopulated. Without this guard, the
    // locally sent message would be silently overwritten, making it appear
    // to disappear from the conversation after the next reload.
    final existingRaw = _messagesBox.get(cleanMessage.id);
    if (existingRaw is Map) {
      final existing = MessageModel.fromMap(existingRaw);
      if (existing.isMine && !cleanMessage.isMine) return;
    }

    await _messagesBox.put(cleanMessage.id, cleanMessage.toMap());
    await upsertConversationFromMessage(cleanMessage);
  }

  Future<int> deleteExpiredMessages() async {
    final now = DateTime.now();
    final keysToDelete = <dynamic>[];
    final affectedConversationIds = <String>{};

    for (final key in _messagesBox.keys) {
      final raw = _messagesBox.get(key);
      if (raw is! Map) continue;

      final expiresAtMillis = raw['expiresAtMillis'];
      if (expiresAtMillis == null) continue;

      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        expiresAtMillis is int
            ? expiresAtMillis
            : expiresAtMillis is double
                ? expiresAtMillis.toInt()
                : int.tryParse('$expiresAtMillis') ?? 0,
      );

      if (now.isAfter(expiresAt)) {
        keysToDelete.add(key);
        affectedConversationIds.add(
          _normalizeConversationId((raw['conversationId'] ?? '').toString()),
        );
      }
    }

    for (final key in keysToDelete) {
      await _messagesBox.delete(key);
    }

    for (final id in affectedConversationIds) {
      await _rebuildOrRemoveConversation(id, preserveRecentEmptyShell: false);
    }

    return keysToDelete.length;
  }

  Future<int> deleteMessagesForConversation(
    String conversationId, {
    DateTime? deletedAt,
    bool markDeleted = true,
  }) async {
    // Backwards-compatible wrapper: in VaultChat, deleting a conversation is a
    // privacy wipe, not a simple "clear history" action.  Keep this method
    // name for older callers, but route it through the hard-delete path.
    return deleteConversationCompletely(
      conversationId,
      deletedAt: deletedAt,
      markDeleted: markDeleted,
    );
  }

  Future<int> deleteConversationCompletely(
    String conversationId, {
    DateTime? deletedAt,
    bool markDeleted = true,
  }) async {
    final normalizedConversationId = _normalizeConversationId(conversationId);
    if (normalizedConversationId.isEmpty) return 0;

    final cutoff = deletedAt ?? DateTime.now();
    if (markDeleted) {
      await _markConversationDeleted(normalizedConversationId, cutoff);
    }

    final keysToDelete = <dynamic>[];

    for (final key in _messagesBox.keys) {
      final raw = _messagesBox.get(key);
      if (raw is! Map) continue;

      final storedConversationId = _normalizeConversationId(
        (raw['conversationId'] ?? '').toString(),
      );
      if (storedConversationId == normalizedConversationId) {
        keysToDelete.add(key);
      }
    }

    for (final key in keysToDelete) {
      await _messagesBox.delete(key);
    }

    // Remove every possible shell/mapping for this thread.  Do NOT rebuild here:
    // rebuilding is exactly what caused "Unknown contact" ghost threads after
    // delete and allowed the still-mounted ChatScreen to continue sending.
    await _conversationsBox.delete(normalizedConversationId);
    await _conversationsBox.delete(conversationId.trim());

    return keysToDelete.length;
  }

  Future<bool> isConversationDeleted(String conversationId) async {
    return _deletedAtForConversation(conversationId) != null;
  }

  Future<void> deleteMessage(String messageId) async {
    final raw = _messagesBox.get(messageId);
    String? conversationId;
    if (raw is Map) {
      conversationId = (raw['conversationId'] ?? '').toString();
    }
    await _messagesBox.delete(messageId);
    if (conversationId != null) {
      await _rebuildOrRemoveConversation(conversationId);
    }
  }

  Future<void> upsertConversationFromMessage(MessageModel message) async {
    final canonicalId = _canonicalConversationIdFromMessage(message);
    final conversationId = canonicalId.isNotEmpty
        ? canonicalId
        : _normalizeConversationId(message.conversationId);
    if (conversationId.isEmpty) return;
    if (message.isExpired) return;
    if (_isBlockedByTombstone(conversationId, message.createdAt)) return;

    final existingRaw = _conversationsBox.get(conversationId);
    final existing = existingRaw is Map
        ? ConversationModel.fromMap(existingRaw)
        : null;

    final peerLabel = _cleanPeerLabel(
      proposed: message.isMine ? null : message.senderLabel,
      existing: existing?.peerLabel,
      peerPublicKey: message.peerPublicKey,
    );

    final conversation = ConversationModel(
      id: conversationId,
      myPublicKey: message.isMine
          ? message.senderPublicKey
          : message.recipientPublicKey,
      peerPublicKey: message.peerPublicKey,
      peerLabel: peerLabel,
      lastMessageText: _previewText(message.text),
      updatedAt: message.createdAt,
      unreadCount: existing?.unreadCount ?? 0,
    );

    await _conversationsBox.put(conversationId, conversation.toMap());
  }

  Future<List<MessageModel>> loadConversation(String conversationId) async {
    final normalizedConversationId = _normalizeConversationId(conversationId);
    if (normalizedConversationId.isEmpty) return <MessageModel>[];

    final messages = <MessageModel>[];

    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;
      final message = MessageModel.fromMap(raw);
      if (_normalizeConversationId(message.conversationId) !=
          normalizedConversationId) {
        continue;
      }
      if (message.isExpired) continue;
      if (_isBlockedByTombstone(normalizedConversationId, message.createdAt)) {
        continue;
      }
      messages.add(message);
    }

    return _deduplicateAndSort(messages);
  }

  /// Pagination: load [pageSize] messages before [before] (exclusive).
  /// Returns messages in chronological order (oldest first).
  /// First page: call with [before] = null / [beforeId] = null.
  ///
  /// The cursor is an (createdAt, id) pair so that messages sharing the same
  /// timestamp are never split across page boundaries (Req 7).
  ///
  /// Usage example in ChatScreen:
  ///   final page = await storageService.loadConversationPage(
  ///     conversationId, pageSize: 50,
  ///     before: oldest?.createdAt, beforeId: oldest?.id);
  Future<List<MessageModel>> loadConversationPage(
    String conversationId, {
    int pageSize = 50,
    DateTime? before,
    String? beforeId,
  }) async {
    final all = await loadConversation(conversationId);
    // all is already sorted ascending (oldest first) with id as tie-breaker.
    final filtered = before == null
        ? all
        : all.where((m) {
            final cmp = m.createdAt.compareTo(before);
            if (cmp < 0) return true;
            // Same timestamp: keep only messages whose id sorts before the cursor.
            if (cmp == 0 && beforeId != null) return m.id.compareTo(beforeId) < 0;
            return false;
          }).toList();

    if (filtered.length <= pageSize) return filtered;
    return filtered.sublist(filtered.length - pageSize);
  }

  Future<List<ConversationModel>> loadConversations() async {
    // Note: sanitizeStorage() is intentionally NOT called here on every load.
    // It runs once at open() and is called explicitly by the expiry timer.
    // Calling it here caused a race condition after restore: restored conversations
    // with expired messages would be immediately deleted before the UI could display them.

    final latestMessages = <String, MessageModel>{};

    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;
      final message = MessageModel.fromMap(raw);
      final canonicalId = _canonicalConversationIdFromMessage(message);
      if (canonicalId.isEmpty) continue;
      if (message.isExpired) continue;
      if (_isBlockedByTombstone(canonicalId, message.createdAt)) continue;

      final existing = latestMessages[canonicalId];
      if (existing == null || message.createdAt.isAfter(existing.createdAt)) {
        latestMessages[canonicalId] = message.copyWith(conversationId: canonicalId);
      }
    }

    final byId = <String, ConversationModel>{};

    for (final key in _conversationsBox.keys) {
      final raw = _conversationsBox.get(key);
      if (raw is! Map) continue;

      final stored = ConversationModel.fromMap(raw);
      final canonicalId = _canonicalConversationId(
        stored.myPublicKey,
        stored.peerPublicKey,
      );
      if (canonicalId.isEmpty) {
        await _conversationsBox.delete(key);
        continue;
      }

      final latest = latestMessages[canonicalId];

      // Check if there are ANY messages (including expired) for this conversation.
      // If all messages are expired but the conversation shell was recently saved
      // (e.g. just restored from backup), keep it visible so the user can see it.
      // The expiry timer will handle deletion of expired messages asynchronously.
      final hasAnyMessage = _messagesBox.values.any((raw) {
        if (raw is! Map) return false;
        final msg = MessageModel.fromMap(raw);
        final cid = _canonicalConversationId(
          msg.senderPublicKey, msg.recipientPublicKey);
        return cid == canonicalId;
      });

      // Keep the conversation shell if:
      // - there are non-expired messages (latest != null), OR
      // - there are any messages (even expired), OR
      // - the shell itself exists with valid keys (contact still reachable)
      // We never delete a valid conversation shell based on time alone.
      final hasValidShell = _looksLikePublicKey(stored.peerPublicKey) &&
          _looksLikePublicKey(stored.myPublicKey);

      final hasUsableLocalShell = latest == null &&
          (hasAnyMessage || hasValidShell);

      if (latest == null && !hasUsableLocalShell) {
        await _conversationsBox.delete(key);
        continue;
      }

      byId[canonicalId] = stored.copyWith(id: canonicalId);
    }

    for (final entry in latestMessages.entries) {
      final message = entry.value;
      final existing = byId[entry.key];

      final peerLabel = _cleanPeerLabel(
        proposed: message.isMine ? null : message.senderLabel,
        existing: existing?.peerLabel,
        peerPublicKey: message.peerPublicKey,
      );

      final conversation = ConversationModel(
        id: entry.key,
        myPublicKey: message.isMine
            ? message.senderPublicKey
            : message.recipientPublicKey,
        peerPublicKey: message.peerPublicKey,
        peerLabel: peerLabel,
        lastMessageText: _previewText(message.text),
        updatedAt: message.createdAt,
        unreadCount: existing?.unreadCount ?? 0,
      );

      await _conversationsBox.put(entry.key, conversation.toMap());
      byId[entry.key] = conversation;
    }

    final conversations = byId.values
        .where((c) => _looksLikePublicKey(c.peerPublicKey))
        .toList();

    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return conversations;
  }

  Future<DateTime?> newestMessageTimeForConversation(
    String conversationId,
  ) async {
    final messages = await loadConversation(conversationId);
    if (messages.isEmpty) return null;
    return messages.last.createdAt;
  }

  Future<DateTime?> nextExpiryTimeForConversation(String conversationId) async {
    final normalizedConversationId = _normalizeConversationId(conversationId);
    if (normalizedConversationId.isEmpty) return null;

    DateTime? nextExpiry;
    final now = DateTime.now();

    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;

      final storedConversationId = _normalizeConversationId(
        (raw['conversationId'] ?? '').toString(),
      );
      if (storedConversationId != normalizedConversationId) continue;

      final expiresAt = _expiresAtFromRaw(raw);
      if (expiresAt == null) continue;
      if (!expiresAt.isAfter(now)) continue;

      if (nextExpiry == null || expiresAt.isBefore(nextExpiry)) {
        nextExpiry = expiresAt;
      }
    }

    return nextExpiry;
  }

  Future<void> sanitizeStorage() async {
    final now = DateTime.now();
    final messageKeysToDelete = <dynamic>[];
    final affectedConversationIds = <String>{};

    for (final key in _messagesBox.keys) {
      final raw = _messagesBox.get(key);
      if (raw is! Map) {
        messageKeysToDelete.add(key);
        continue;
      }

      final conversationId = _normalizeConversationId(
        (raw['conversationId'] ?? '').toString(),
      );
      final createdAt = _createdAtFromRaw(raw);
      final expiresAt = _expiresAtFromRaw(raw);

      if (conversationId.isEmpty || createdAt == null) {
        messageKeysToDelete.add(key);
        continue;
      }

      final message = MessageModel.fromMap(raw);
      final canonicalId = _canonicalConversationIdFromMessage(message);
      if (canonicalId.isEmpty) {
        messageKeysToDelete.add(key);
        continue;
      }

      if (canonicalId != conversationId) {
        await _messagesBox.put(
          key,
          message.copyWith(conversationId: canonicalId).toMap(),
        );
        affectedConversationIds
          ..add(conversationId)
          ..add(canonicalId);
      }

      final expired = expiresAt != null && now.isAfter(expiresAt);
      final tombstoned = _isBlockedByTombstone(canonicalId, createdAt);
      if (expired || tombstoned) {
        messageKeysToDelete.add(key);
        affectedConversationIds.add(canonicalId);
      }
    }

    for (final key in messageKeysToDelete) {
      await _messagesBox.delete(key);
    }

    final conversationIds = <String>{};
    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;
      final conversationId = _normalizeConversationId(
        (raw['conversationId'] ?? '').toString(),
      );
      if (conversationId.isNotEmpty) conversationIds.add(conversationId);
    }
    conversationIds.addAll(affectedConversationIds);

    final conversationKeysToDelete = <dynamic>[];
    final canonicalConversations = <String, ConversationModel>{};

    for (final key in _conversationsBox.keys) {
      final raw = _conversationsBox.get(key);
      if (raw is! Map) {
        conversationKeysToDelete.add(key);
        continue;
      }

      final stored = ConversationModel.fromMap(raw);
      final canonicalId = _canonicalConversationId(
        stored.myPublicKey,
        stored.peerPublicKey,
      );

      if (canonicalId.isEmpty) {
        conversationKeysToDelete.add(key);
        continue;
      }

      conversationIds.add(canonicalId);
      final previous = canonicalConversations[canonicalId];
      if (previous == null || stored.updatedAt.isAfter(previous.updatedAt)) {
        canonicalConversations[canonicalId] = stored.copyWith(
          id: canonicalId,
          peerLabel: _cleanPeerLabel(
            proposed: stored.peerLabel,
            existing: stored.peerLabel,
            peerPublicKey: stored.peerPublicKey,
          ),
        );
      }

      if (_normalizeConversationId(key.toString()) != canonicalId ||
          _normalizeConversationId(stored.id) != canonicalId) {
        conversationKeysToDelete.add(key);
      }
    }

    for (final key in conversationKeysToDelete) {
      await _conversationsBox.delete(key);
    }

    for (final entry in canonicalConversations.entries) {
      await _conversationsBox.put(entry.key, entry.value.toMap());
    }

    for (final conversationId in conversationIds) {
      await _rebuildOrRemoveConversation(
        conversationId,
        // Preserve shells even when all messages are expired.
        // The inbox will show the conversation with empty state rather than
        // making it disappear, which is less confusing for the user.
        preserveRecentEmptyShell: true,
      );
    }
  }


  Future<Map<String, dynamic>> exportBackupSnapshot({
    required String myPublicKey,
  }) async {
    await sanitizeStorage();

    final cleanMyKey = _normalizePublicKey(myPublicKey);
    final messages = <Map<String, dynamic>>[];
    final conversations = <Map<String, dynamic>>[];

    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;
      final message = MessageModel.fromMap(raw);
      if (message.isExpired) continue;
      final sender = _normalizePublicKey(message.senderPublicKey);
      final recipient = _normalizePublicKey(message.recipientPublicKey);
      if (cleanMyKey.isNotEmpty && sender != cleanMyKey && recipient != cleanMyKey) {
        continue;
      }
      final canonicalId = _canonicalConversationIdFromMessage(message);
      if (canonicalId.isEmpty) continue;
      if (_isBlockedByTombstone(canonicalId, message.createdAt)) continue;
      messages.add(message.copyWith(conversationId: canonicalId).toMap());
    }

    for (final raw in _conversationsBox.values) {
      if (raw is! Map) continue;
      final conversation = ConversationModel.fromMap(raw);
      final canonicalId = _canonicalConversationId(
        conversation.myPublicKey,
        conversation.peerPublicKey,
      );
      if (canonicalId.isEmpty) continue;
      if (cleanMyKey.isNotEmpty &&
          _normalizePublicKey(conversation.myPublicKey) != cleanMyKey) {
        continue;
      }
      conversations.add(conversation.copyWith(id: canonicalId).toMap());
    }

    return <String, dynamic>{
      'schema': 1,
      'messages': messages,
      'conversations': conversations,
    };
  }

  Future<void> restoreBackupSnapshot({
    required List<MessageModel> messages,
    required List<ConversationModel> conversations,
    bool replaceExisting = true,
  }) async {
    if (replaceExisting) {
      await _messagesBox.clear();
      await _conversationsBox.clear();
      await _deletedConversationsBox.clear();
    }

    for (final conversation in conversations) {
      final canonicalId = _canonicalConversationId(
        conversation.myPublicKey,
        conversation.peerPublicKey,
      );
      if (canonicalId.isEmpty) continue;
      await _conversationsBox.put(
        canonicalId,
        conversation.copyWith(
          id: canonicalId,
          peerLabel: _cleanPeerLabel(
            proposed: conversation.peerLabel,
            existing: conversation.peerLabel,
            peerPublicKey: conversation.peerPublicKey,
          ),
        ).toMap(),
      );
    }

    // Track which conversation IDs have messages so we can ensure
    // the conversation shell exists even for expired messages.
    final restoredConversationIds = <String>{};

    for (final message in messages) {
      // Use direct box.put during restore to bypass shouldAcceptMessage filtering.
      // We deliberately restore ALL non-tombstoned messages regardless of expiry —
      // the global expiry timer will purge them at its next tick (within 30s).
      if (message.id.trim().isEmpty) continue;
      final canonicalId = _canonicalConversationId(
        message.senderPublicKey,
        message.recipientPublicKey,
      );
      if (canonicalId.isEmpty) continue;
      final cleanMsg = _normalizeConversationId(message.conversationId) != canonicalId
          ? message.copyWith(conversationId: canonicalId)
          : message;
      if (_isBlockedByTombstone(canonicalId, cleanMsg.createdAt)) continue;
      await _messagesBox.put(cleanMsg.id, cleanMsg.toMap());
      restoredConversationIds.add(canonicalId);
      // Only upsert conversation from message if NOT expired —
      // upsertConversationFromMessage skips expired messages and would leave
      // the conversation shell missing if ALL messages are expired.
      if (!cleanMsg.isExpired) {
        await upsertConversationFromMessage(cleanMsg);
      }
    }

    // Ensure conversation shells exist for conversations whose ALL messages
    // are expired. Without this, the inbox would show nothing after restore
    // until the next non-expired message arrives.
    for (final conversationId in restoredConversationIds) {
      final exists = _conversationsBox.get(conversationId);
      if (exists == null) {
        // No shell was created by upsertConversationFromMessage (all messages
        // were expired). Create a minimal shell from the conversations list
        // that was restored above so the peer is visible in the inbox.
        final rawConv = _conversationsBox.keys
            .where((k) => _normalizeConversationId(k.toString()) == conversationId)
            .firstOrNull;
        if (rawConv == null) {
          // Create empty shell so inbox shows the conversation.
          // Label will be resolved from contacts in _reloadConversations.
          final firstMsg = messages.where((m) {
            final cid = _canonicalConversationId(
              m.senderPublicKey, m.recipientPublicKey);
            return cid == conversationId;
          }).firstOrNull;
          if (firstMsg != null) {
            final shell = ConversationModel(
              id: conversationId,
              myPublicKey: firstMsg.isMine
                  ? firstMsg.senderPublicKey
                  : firstMsg.recipientPublicKey,
              peerPublicKey: firstMsg.peerPublicKey,
              peerLabel: firstMsg.senderLabel.trim().isNotEmpty
                  ? firstMsg.senderLabel
                  : (firstMsg.peerPublicKey.trim().length >= 8
                      ? firstMsg.peerPublicKey.trim().substring(0, 8)
                      : unknownContactLabel),
              lastMessageText: _previewText(firstMsg.text),
              updatedAt: firstMsg.createdAt,
              unreadCount: 0,
            );
            await _conversationsBox.put(conversationId, shell.toMap());
          }
        }
      }
    }

    // Note: intentionally NOT calling sanitizeStorage() here.
    // sanitizeStorage() would immediately delete restored messages whose TTL
    // has expired (between backup creation and restore), causing conversations
    // to flash briefly then disappear. The global expiry timer in VaultChatRoot
    // runs every 30 seconds and will handle expired messages after the UI
    // has had a chance to display the restored conversations.
  }

  Future<void> clearAll() async {
    await _messagesBox.clear();
    await _conversationsBox.clear();
    await _deletedConversationsBox.clear();
  }

  Future<void> close() async {
    await _messagesBox.close();
    await _conversationsBox.close();
    await _deletedConversationsBox.close();
  }

  Future<void> _rebuildOrRemoveConversation(
    String conversationId, {
    bool preserveRecentEmptyShell = true,
  }) async {
    final normalizedConversationId = _normalizeConversationId(conversationId);
    if (normalizedConversationId.isEmpty) return;

    final messages = await loadConversation(normalizedConversationId);
    if (messages.isEmpty) {
      final raw = _conversationsBox.get(normalizedConversationId);
      if (raw is Map) {
        final existing = ConversationModel.fromMap(raw);
        final canonicalId = _canonicalConversationId(
          existing.myPublicKey,
          existing.peerPublicKey,
        );

        // Only remove the shell if:
        // 1. The canonical ID doesn't match (corrupt entry), OR
        // 2. We are explicitly NOT asked to preserve shells
        // Never remove based on age alone — the conversation contact is still
        // valid even if all messages have expired or been deleted.
        final shouldRemoveEmptyShell = canonicalId != normalizedConversationId ||
            !preserveRecentEmptyShell;

        if (shouldRemoveEmptyShell) {
          await _conversationsBox.delete(normalizedConversationId);
          return;
        }

        final cleaned = existing.copyWith(
          id: normalizedConversationId,
          peerLabel: _cleanPeerLabel(
            proposed: existing.peerLabel,
            existing: existing.peerLabel,
            peerPublicKey: existing.peerPublicKey,
          ),
          lastMessageText: '',
          unreadCount: 0,
        );
        await _conversationsBox.put(normalizedConversationId, cleaned.toMap());
      }
      return;
    }

    final latest = messages.last;
    await upsertConversationFromMessage(latest);
  }

  DateTime? _createdAtFromRaw(Map<dynamic, dynamic> raw) {
    final createdAtMillis = raw['createdAtMillis'];
    // Hive on older Android versions (e.g. Android 10) sometimes stores
    // integer values as doubles (e.g. 1716298800000.0). Handle all numeric
    // types to avoid silently deleting valid messages.
    final millis = createdAtMillis is int
        ? createdAtMillis
        : createdAtMillis is double
            ? createdAtMillis.toInt()
            : int.tryParse('$createdAtMillis');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  DateTime? _expiresAtFromRaw(Map<dynamic, dynamic> raw) {
    final expiresAtMillis = raw['expiresAtMillis'];
    if (expiresAtMillis == null) return null;
    final millis = expiresAtMillis is int
        ? expiresAtMillis
        : expiresAtMillis is double
            ? expiresAtMillis.toInt()
            : int.tryParse('$expiresAtMillis');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  List<MessageModel> _deduplicateAndSort(List<MessageModel> messages) {
    final byId = <String, MessageModel>{};

    for (final message in messages) {
      final id = message.id.trim();
      if (id.isEmpty) continue;
      byId[id] = message;
    }

    final result = byId.values.toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });

    return result;
  }
}
