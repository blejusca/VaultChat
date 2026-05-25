part of vault_chat.conversation_storage_service;

extension ConversationStorageServiceOperations on ConversationStorageService {
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
        dynamic rawConv;
        for (final key in _conversationsBox.keys) {
          if (_normalizeConversationId(key.toString()) == conversationId) {
            rawConv = key;
            break;
          }
        }
        if (rawConv == null) {
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
}
