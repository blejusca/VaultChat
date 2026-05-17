import 'package:hive_flutter/hive_flutter.dart';

import '../models/conversation_model.dart';
import '../models/message_model.dart';

class ConversationStorageService {
  ConversationStorageService._({
    required Box messagesBox,
    required Box conversationsBox,
  })  : _messagesBox = messagesBox,
        _conversationsBox = conversationsBox;

  static const String _messagesBoxName = 'secure_chat_messages_v3';
  static const String _conversationsBoxName = 'secure_chat_conversations_v3';

  final Box _messagesBox;
  final Box _conversationsBox;


  static Future<void> deleteAllLocalData() async {
    await Hive.initFlutter();

    if (Hive.isBoxOpen(_messagesBoxName)) {
      await Hive.box(_messagesBoxName).close();
    }
    if (Hive.isBoxOpen(_conversationsBoxName)) {
      await Hive.box(_conversationsBoxName).close();
    }

    try {
      await Hive.deleteBoxFromDisk(_messagesBoxName);
    } catch (_) {}
    try {
      await Hive.deleteBoxFromDisk(_conversationsBoxName);
    } catch (_) {}
  }

  static Future<ConversationStorageService> open() async {
    await Hive.initFlutter();
    final messagesBox = await Hive.openBox(_messagesBoxName);
    final conversationsBox = await Hive.openBox(_conversationsBoxName);

    return ConversationStorageService._(
      messagesBox: messagesBox,
      conversationsBox: conversationsBox,
    );
  }

  Future<void> saveMessage(MessageModel message) async {
    if (message.id.trim().isEmpty) return;
    if (message.conversationId.trim().isEmpty) return;

    await _messagesBox.put(message.id, message.toMap());
    await upsertConversationFromMessage(message);
  }

  Future<void> upsertConversationFromMessage(MessageModel message) async {
    final conversationId = message.conversationId.trim();
    if (conversationId.isEmpty) return;

    final existingRaw = _conversationsBox.get(conversationId);
    final existing = existingRaw is Map
        ? ConversationModel.fromMap(existingRaw)
        : null;

    final peerLabel = message.peerPublicKey.length >= 8
        ? message.peerPublicKey.substring(0, 8)
        : message.peerPublicKey;

    final conversation = ConversationModel(
      id: conversationId,
      myPublicKey: message.isMine
          ? message.senderPublicKey
          : message.recipientPublicKey,
      peerPublicKey: message.peerPublicKey,
      peerLabel: existing?.peerLabel.isNotEmpty == true
          ? existing!.peerLabel
          : peerLabel,
      lastMessageText: message.text,
      updatedAt: message.createdAt,
      unreadCount: existing?.unreadCount ?? 0,
    );

    await _conversationsBox.put(conversationId, conversation.toMap());
  }

  Future<List<MessageModel>> loadConversation(String conversationId) async {
    final normalizedConversationId = conversationId.trim().toLowerCase();
    if (normalizedConversationId.isEmpty) return <MessageModel>[];

    final messages = <MessageModel>[];

    for (final raw in _messagesBox.values) {
      if (raw is! Map) continue;
      final message = MessageModel.fromMap(raw);
      if (message.conversationId.trim().toLowerCase() ==
          normalizedConversationId) {
        messages.add(message);
      }
    }

    return _deduplicateAndSort(messages);
  }

  Future<List<ConversationModel>> loadConversations() async {
    final conversations = <ConversationModel>[];

    for (final raw in _conversationsBox.values) {
      if (raw is! Map) continue;
      conversations.add(ConversationModel.fromMap(raw));
    }

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

  Future<void> clearAll() async {
    await _messagesBox.clear();
    await _conversationsBox.clear();
  }

  Future<void> close() async {
    await _messagesBox.close();
    await _conversationsBox.close();
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
