import 'dart:async';

import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/contact_model.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../services/contact_storage_service.dart';
import '../services/conversation_storage_service.dart';
import '../services/identity_backup_service.dart';
import '../services/nostr_connection_service.dart';
import '../services/secure_key_storage_service.dart';

/// Immutable state exposed by [AppController] to the UI.
class AppState {
  final bool isLoading;
  final String? startupError;
  final List<ConversationModel> conversations;
  final Map<String, ContactModel> contactsByKey;
  final SecureChatConnectionSnapshot connectionSnapshot;
  final String publicKey;

  const AppState({
    required this.isLoading,
    this.startupError,
    required this.conversations,
    required this.contactsByKey,
    required this.connectionSnapshot,
    required this.publicKey,
  });

  AppState copyWith({
    bool? isLoading,
    String? startupError,
    List<ConversationModel>? conversations,
    Map<String, ContactModel>? contactsByKey,
    SecureChatConnectionSnapshot? connectionSnapshot,
    String? publicKey,
  }) {
    return AppState(
      isLoading: isLoading ?? this.isLoading,
      startupError: startupError,
      conversations: conversations ?? this.conversations,
      contactsByKey: contactsByKey ?? this.contactsByKey,
      connectionSnapshot: connectionSnapshot ?? this.connectionSnapshot,
      publicKey: publicKey ?? this.publicKey,
    );
  }

  static AppState initial() => AppState(
        isLoading: true,
        conversations: const [],
        contactsByKey: const {},
        connectionSnapshot: SecureChatConnectionSnapshot(
          state: SecureChatConnectionState.idle,
          label: 'Initializing...',
          updatedAt: DateTime.now(),
        ),
        publicKey: '',
      );
}

/// ViewModel that manages all app business logic.
/// The [VaultChatRoot] widget listens to [stateStream] and rebuilds
/// only when state changes; no setState() in business logic.
class AppController {
  AppController._();

  static const String _lastRecipientKey = 'nostr_last_recipient_hex';
  static const Duration _autoLockAfter = Duration(minutes: 10);
  static const Duration _sensitiveClipboardTtl = Duration(seconds: 90);

  // ── Relay-uri ───────────────────────────────────────────────────────────────
  static const List<String> relayUrls = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.nostr.band',
    'wss://relay.primal.net',
    'wss://nostr.wine',
    'wss://purplepag.es',         // profile relay — reliable for DMs
  ];

  // ── State stream ────────────────────────────────────────────────────────────
  final _stateController = StreamController<AppState>.broadcast();
  Stream<AppState> get stateStream => _stateController.stream;

  AppState _state = AppState.initial();
  AppState get state => _state;

  void _emit(AppState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  // ── Internal dependencies ──────────────────────────────────────────────────────
  final _nostr = Nostr.instance;
  NostrKeyPairs? _keyPair;
  ConversationStorageService? _storageService;
  ContactStorageService? _contactService;
  NostrConnectionService? _connectionService;

  StreamSubscription<SecureChatConnectionSnapshot>? _statusSub;
  StreamSubscription<MessageModel>? _incomingMsgSub;
  StreamSubscription<RemoteConversationCommand>? _commandSub;

  Timer? _clipboardClearTimer;
  String? _lastSensitiveClipboard;

  String get privateKey => _keyPair?.private ?? '';

  // ── Factory ─────────────────────────────────────────────────────────────────

  static Future<AppController> create() async {
    final ctrl = AppController._();
    await ctrl._initialize();
    return ctrl;
  }

  // ── Inizializare ────────────────────────────────────────────────────────────

  Future<void> _initialize() async {
    try {
      await _loadOrCreateKeys();
      _storageService = await ConversationStorageService.open();
      _contactService = await ContactStorageService.open();
      await _startNostrService();
      await _reloadConversations();
      _emit(_state.copyWith(isLoading: false));
    } catch (e) {
      _emit(_state.copyWith(isLoading: false, startupError: 'Initialization error: $e'));
    }
  }

  Future<void> _loadOrCreateKeys() async {
    String? savedKey;
    for (var attempt = 0; attempt < 3; attempt++) {
      savedKey = await SecureKeyStorageService.readPrivateKey();
      if (savedKey != null && savedKey.trim().isNotEmpty) break;
      if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    if (savedKey != null && savedKey.trim().isNotEmpty) {
      _keyPair = _nostr.keys.generateKeyPairFromExistingPrivateKey(savedKey.trim());
    } else {
      final newPair = _nostr.keys.generateKeyPair();
      await SecureKeyStorageService.writePrivateKey(newPair.private);
      await SecureKeyStorageService.writeIdentityActivatedAt(DateTime.now());
      _keyPair = newPair;
    }
    _emit(_state.copyWith(publicKey: _keyPair?.public ?? ''));
  }

  Future<void> _startNostrService() async {
    final keyPair = _keyPair;
    if (keyPair == null) return;

    final identityActivatedAt = await SecureKeyStorageService.readIdentityActivatedAt();

    final service = NostrConnectionService(
      relayUrls: relayUrls,
      keyPair: keyPair,
      identityActivatedAt: identityActivatedAt,
    );
    _connectionService = service;

    _statusSub = service.statusStream.listen((snapshot) {
      _emit(_state.copyWith(connectionSnapshot: snapshot));
    });

    _incomingMsgSub = service.messageStream.listen((message) async {
      final localLabel = await _contactService?.displayNameFor(message.peerPublicKey);
      final safeLabel = localLabel ??
          (message.peerPublicKey.trim().length >= 8
              ? message.peerPublicKey.trim().substring(0, 8)
              : message.senderLabel);
      final enrichedMessage = message.copyWith(senderLabel: safeLabel);
      await _storageService?.saveMessage(enrichedMessage);
      await _reloadConversations();
    });

    _commandSub = service.commandStream.listen((command) async {
      if (!command.isDeleteConversation) return;
      final age = DateTime.now().difference(command.createdAt);
      if (age.inMinutes >= 2) return;
      await _storageService?.deleteConversationCompletely(
        command.conversationId, deletedAt: command.createdAt);
      // Remote delete must not remove the local contact label.
      // It only removes the conversation/messages when the delete command arrives.
      await _reloadConversations();
    });

    await service.start();
  }

  Future<void> _reloadConversations() async {
    final storage = _storageService;
    if (storage == null) return;

    final conversations = await storage.loadConversations();
    final contacts = await _contactService?.loadContacts() ?? <ContactModel>[];
    final byKey = <String, ContactModel>{
      for (final c in contacts) c.publicKey.toLowerCase(): c,
    };

    final displayed = conversations.map((conv) {
      final label = byKey[conv.peerPublicKey.toLowerCase()]?.label;
      if (label == null || label.isEmpty) return conv;
      return conv.copyWith(peerLabel: label);
    }).toList();

    _emit(_state.copyWith(conversations: displayed, contactsByKey: byKey));
  }

  Future<void> _restartConnectionForIdentity() async {
    await _statusSub?.cancel();
    await _incomingMsgSub?.cancel();
    await _commandSub?.cancel();
    await _connectionService?.dispose();
    _connectionService = null;
    await _startNostrService();
  }

  // ── Public actions ─────────────────────────────────────────────────────────

  Future<void> manualReconnect() async {
    await _connectionService?.reconnect(reason: 'Manual', force: true);
  }

  Future<void> reloadConversations() => _reloadConversations();

  NostrConnectionService? get connectionService => _connectionService;
  ConversationStorageService? get storageService => _storageService;
  ContactStorageService? get contactService => _contactService;

  // ── Clipboard securizat ─────────────────────────────────────────────────────

  Future<void> copyPublicKey(BuildContext context) async {
    final key = _keyPair?.public ?? '';
    if (key.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: key));
  }

  Future<void> copySensitive(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _lastSensitiveClipboard = value;
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = Timer(_sensitiveClipboardTtl, () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == _lastSensitiveClipboard) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
      _lastSensitiveClipboard = null;
    });
  }

  // ── Contacte ────────────────────────────────────────────────────────────────

  Future<void> upsertContact({
    required String publicKey,
    required String displayName,
  }) async {
    await _contactService?.upsertContact(
      publicKey: publicKey, displayName: displayName);
    await _reloadConversations();
  }

  Future<void> deleteContact(String publicKey) async {
    await _contactService?.deleteContact(publicKey);
    await _reloadConversations();
  }

  // ── Conversations ─────────────────────────────────────────────────────────────

  Future<void> deleteConversation(String conversationId) async {
    await _storageService?.deleteConversationCompletely(conversationId);
    await _reloadConversations();
  }

  Future<String?> lastRecipient() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastRecipientKey);
  }

  Future<void> setLastRecipient(String publicKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastRecipientKey, publicKey);
  }

  // ── Backup / Restore ────────────────────────────────────────────────────────

  Future<String> createBackup(String password) async {
    final storage = _storageService;
    final contacts = await _contactService?.loadContacts() ?? <ContactModel>[];
    final pk = _keyPair?.public.toLowerCase() ?? '';
    final storageSnapshot = storage != null
        ? await storage.exportBackupSnapshot(myPublicKey: pk)
        : const <String, dynamic>{
            'schema': 1,
            'messages': <Map<String, dynamic>>[],
            'conversations': <Map<String, dynamic>>[],
          };

    return IdentityBackupService.createEncryptedBackup(
      privateKey: _keyPair?.private ?? '',
      publicKey: pk,
      password: password,
      contacts: contacts,
      storageSnapshot: storageSnapshot,
    );
  }

  Future<void> restoreFromBackup(String payload, String password) async {
    final normalized = IdentityBackupService.normalizeRestorePayload(payload);
    final restored = await IdentityBackupService.decryptBackup(normalized, password);

    final restoredPair = _nostr.keys
        .generateKeyPairFromExistingPrivateKey(restored.privateKey.trim());
    if (restoredPair.public.isEmpty) {
      throw StateError('Invalid private key.');
    }

    await SecureKeyStorageService.writePrivateKey(restored.privateKey.trim());
    await SecureKeyStorageService.writeIdentityActivatedAt(DateTime.now());
    _keyPair = restoredPair;

    await _contactService?.close();
    _contactService = await ContactStorageService.open();
    await _contactService?.clearAll();
    for (final c in restored.contacts) {
      await _contactService?.upsertContact(
          publicKey: c.publicKey, displayName: c.displayName);
    }

    await _storageService?.close();
    _storageService = await ConversationStorageService.open();
    await _storageService?.restoreBackupSnapshot(
      messages: restored.messages,
      conversations: restored.conversations,
      replaceExisting: true,
    );

    _emit(_state.copyWith(publicKey: restoredPair.public));
    await _restartConnectionForIdentity();
    await _reloadConversations();
  }

  // ── Auto-lock ───────────────────────────────────────────────────────────────

  /// Returns true if the app must be locked (background too long).
  bool shouldLock(DateTime? backgroundedAt) {
    if (backgroundedAt == null) return false;
    return DateTime.now().difference(backgroundedAt) >= _autoLockAfter;
  }

  Future<void> reconnectAfterResume() async {
    await _connectionService?.reconnect(reason: 'Returning to app', force: true);
    await _reloadConversations();
  }

  // ── Dispose ─────────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await _statusSub?.cancel();
    await _incomingMsgSub?.cancel();
    await _commandSub?.cancel();
    _clipboardClearTimer?.cancel();
    await _connectionService?.dispose();
    await _storageService?.close();
    await _contactService?.close();
    await _stateController.close();
  }
}
