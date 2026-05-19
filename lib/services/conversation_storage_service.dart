import 'package:hive_flutter/hive_flutter.dart';

import '../models/conversation_model.dart';
import '../models/message_model.dart';

class ConversationStorageService {
  ConversationStorageService._({
    required Box messagesBox,
    required Box conversationsBox,
    required Box deletedConversationsBox,
  })  : _messagesBox = messagesBox,
        _conversationsBox = conversationsBox,
        _deletedConversationsBox = deletedConversationsBox;

  static const String _messagesBoxName = 'secure_chat_messages_v3';
  static const String _conversationsBoxName = 'secure_chat_conversations_v3';
  static const String _deletedConversationsBoxName =
      'secure_chat_deleted_conversations_v1';

  final Box _messagesBox;
  final Box _conversationsBox;
  final Box _deletedConversationsBox;

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
  }

  static Future<ConversationStorageService> open() async {
    await Hive.initFlutter();
    final messagesBox = await Hive.openBox(_messagesBoxName);
    final conversationsBox = await Hive.openBox(_conversationsBoxName);
    final deletedConversationsBox =
        await Hive.openBox(_deletedConversationsBoxName);

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
    final cleanMyKey = myPublicKey.trim().toLowerCase();
    final cleanPeerKey = peerPublicKey.trim().toLowerCase();
    if (cleanMyKey.isEmpty || cleanPeerKey.isEmpty) return;

    final conversationId = _normalizeConversationId(
      MessageModel.buildConversationId(cleanMyKey, cleanPeerKey),
    );
    if (conversationId.isEmpty) return;

    final existingRaw = _conversationsBox.get(conversationId);
    final existing = existingRaw is Map
        ? ConversationModel.fromMap(existingRaw)
        : null;

    final shortLabel = cleanPeerKey.length >= 8
        ? cleanPeerKey.substring(0, 8)
        : cleanPeerKey;

    final cleanLabel = peerLabel?.trim();
    final effectiveLabel = cleanLabel != null && cleanLabel.isNotEmpty
        ? cleanLabel
        : (existing?.peerLabel.trim().isNotEmpty == true
            ? existing!.peerLabel
            : shortLabel);

    final conversation = ConversationModel(
      id: conversationId,
      myPublicKey: cleanMyKey,
      peerPublicKey: cleanPeerKey,
      peerLabel: effectiveLabel,
      lastMessageText: existing?.lastMessageText ?? '',
      updatedAt: existing?.updatedAt ?? DateTime.now(),
      unreadCount: existing?.unreadCount ?? 0,
    );

    await _conversationsBox.put(conversationId, conversation.toMap());
  }

  Future<void> saveMessage(MessageModel message) async {
    if (message.id.trim().isEmpty) return;
    if (message.conversationId.trim().isEmpty) return;
    if (!shouldAcceptMessage(message)) return;

    await _messagesBox.put(message.id, message.toMap());
    await upsertConversationFromMessage(message);
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
      await _rebuildOrRemoveConversation(id);
    }

    return keysToDelete.length;
  }

  Future<int> deleteMessagesForConversation(
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
      if (storedConversationId != normalizedConversationId) continue;

      final createdAt = _createdAtFromRaw(raw);
      if (createdAt == null || !createdAt.isAfter(cutoff)) {
        keysToDelete.add(key);
      }
    }

    for (final key in keysToDelete) {
      await _messagesBox.delete(key);
    }

    await _conversationsBox.delete(normalizedConversationId);
    await _conversationsBox.delete(conversationId.trim());
    await _rebuildOrRemoveConversation(normalizedConversationId);

    return keysToDelete.length;
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
    final conversationId = _normalizeConversationId(message.conversationId);
    if (conversationId.isEmpty) return;
    if (message.isExpired) return;
    if (_isBlockedByTombstone(conversationId, message.createdAt)) return;

    final existingRaw = _conversationsBox.get(conversationId);
    final existing = existingRaw is Map
        ? ConversationModel.fromMap(existingRaw)
        : null;

    final shortLabel = message.peerPublicKey.length >= 8
        ? message.peerPublicKey.substring(0, 8)
        : message.peerPublicKey;

    final incomingLabel = message.senderLabel.trim();
    final existingLabel = existing?.peerLabel.trim() ?? '';
    final existingIsShortKey = existingLabel == shortLabel ||
        existingLabel == message.peerPublicKey ||
        existingLabel.isEmpty;

    final peerLabel = incomingLabel.isNotEmpty && existingIsShortKey
        ? incomingLabel
        : (existingLabel.isNotEmpty ? existingLabel : shortLabel);

    final conversation = ConversationModel(
      id: conversationId,
      myPublicKey: message.isMine
          ? message.senderPublicKey
          : message.recipientPublicKey,
      peerPublicKey: message.peerPublicKey,
      peerLabel: peerLabel,
      lastMessageText: message.text,
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

  Future<List<ConversationModel>> loadConversations() async {
    await sanitizeStorage();

    final latestMessages = <String, MessageModel>{};

    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;
      final message = MessageModel.fromMap(raw);
      final conversationId = _normalizeConversationId(message.conversationId);
      if (conversationId.isEmpty) continue;
      if (message.isExpired) continue;
      if (_isBlockedByTombstone(conversationId, message.createdAt)) continue;

      final existing = latestMessages[conversationId];
      if (existing == null || message.createdAt.isAfter(existing.createdAt)) {
        latestMessages[conversationId] = message;
      }
    }

    final byId = <String, ConversationModel>{};

    for (final key in _conversationsBox.keys) {
      final raw = _conversationsBox.get(key);
      if (raw is! Map) continue;

      final stored = ConversationModel.fromMap(raw);
      final conversationId = _normalizeConversationId(
        stored.id.isNotEmpty ? stored.id : key.toString(),
      );
      if (conversationId.isEmpty) continue;

      final tombstone = _deletedAtForConversation(conversationId);
      final latest = latestMessages[conversationId];

      if (tombstone != null && latest == null) {
        await _conversationsBox.delete(key);
        continue;
      }

      byId[conversationId] = stored.copyWith(id: conversationId);
    }

    for (final entry in latestMessages.entries) {
      final message = entry.value;
      final existing = byId[entry.key];

      final shortLabel = message.peerPublicKey.length >= 8
          ? message.peerPublicKey.substring(0, 8)
          : message.peerPublicKey;

      final peerLabel = existing?.peerLabel.trim().isNotEmpty == true
          ? existing!.peerLabel
          : shortLabel;

      final conversation = ConversationModel(
        id: entry.key,
        myPublicKey: message.isMine
            ? message.senderPublicKey
            : message.recipientPublicKey,
        peerPublicKey: message.peerPublicKey,
        peerLabel: peerLabel,
        lastMessageText: message.text,
        updatedAt: message.createdAt,
        unreadCount: existing?.unreadCount ?? 0,
      );

      await _conversationsBox.put(entry.key, conversation.toMap());
      byId[entry.key] = conversation;
    }

    final conversations = byId.values
        .where((c) => c.peerPublicKey.trim().isNotEmpty)
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

      final expired = expiresAt != null && now.isAfter(expiresAt);
      final tombstoned = _isBlockedByTombstone(conversationId, createdAt);
      if (expired || tombstoned) {
        messageKeysToDelete.add(key);
        affectedConversationIds.add(conversationId);
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
    for (final key in _conversationsBox.keys) {
      conversationIds.add(_normalizeConversationId(key.toString()));
    }

    for (final conversationId in conversationIds) {
      await _rebuildOrRemoveConversation(conversationId);
    }
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

  Future<void> _rebuildOrRemoveConversation(String conversationId) async {
    final normalizedConversationId = _normalizeConversationId(conversationId);
    if (normalizedConversationId.isEmpty) return;

    final messages = await loadConversation(normalizedConversationId);
    if (messages.isEmpty) {
      final raw = _conversationsBox.get(normalizedConversationId);
      if (raw is Map) {
        final existing = ConversationModel.fromMap(raw);
        final cleaned = existing.copyWith(
          id: normalizedConversationId,
          lastMessageText: '',
          updatedAt: existing.updatedAt,
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
    final millis = createdAtMillis is int
        ? createdAtMillis
        : int.tryParse('$createdAtMillis');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  DateTime? _expiresAtFromRaw(Map<dynamic, dynamic> raw) {
    final expiresAtMillis = raw['expiresAtMillis'];
    if (expiresAtMillis == null) return null;
    final millis = expiresAtMillis is int
        ? expiresAtMillis
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
