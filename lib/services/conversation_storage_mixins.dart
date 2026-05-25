part of 'conversation_storage_service.dart';

extension ConversationStorageMaintenanceExtension on ConversationStorageService {
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


}

extension ConversationStorageBackupExtension on ConversationStorageService {
  Future<Map<String, dynamic>> exportBackupSnapshot({
    required String myPublicKey,
  }) async {
    await this.sanitizeStorage();

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
        // Create empty shell so inbox shows the conversation.
        // Label will be resolved from contacts in _reloadConversations.
        MessageModel? firstMsg;
        for (final message in messages) {
          final cid = _canonicalConversationId(
            message.senderPublicKey,
            message.recipientPublicKey,
          );
          if (cid == conversationId) {
            firstMsg = message;
            break;
          }
        }
        if (firstMsg != null) {
          final shell = ConversationModel(
            id: conversationId,
            myPublicKey: firstMsg.isMine
                ? firstMsg.senderPublicKey
                : firstMsg.recipientPublicKey,
            peerPublicKey: firstMsg.peerPublicKey,
            peerLabel: firstMsg.senderLabel.trim().isNotEmpty
                ? firstMsg.senderLabel
                : ConversationStorageService.unknownContactLabel,
            lastMessageText: firstMsg.text,
            updatedAt: firstMsg.createdAt,
            unreadCount: 0,
          );
          await _conversationsBox.put(conversationId, shell.toMap());
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

}
