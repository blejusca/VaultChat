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

  static const String unknownContactLabel = 'Contact necunoscut';

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

    // Conversatia a fost recreata explicit de utilizator.
    // Eliminam tombstone-ul pentru a preveni ghost-thread state
    // si pentru a permite reconstruirea curata a conversatiei noi.
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

    // O singura intrare canonica per pereche de chei. Orice cheie veche/non-canonica
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
    // rebuilding is exactly what caused "Contact necunoscut" ghost threads after
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
      final hasUsableLocalShell = latest == null &&
          stored.lastMessageText.trim().isEmpty &&
          DateTime.now().difference(stored.updatedAt).inMinutes <= 10;

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
        lastMessageText: message.text,
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
        final canonicalId = _canonicalConversationId(
          existing.myPublicKey,
          existing.peerPublicKey,
        );

        if (canonicalId != normalizedConversationId ||
            existing.lastMessageText.trim().isEmpty &&
                DateTime.now().difference(existing.updatedAt).inMinutes > 10) {
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
