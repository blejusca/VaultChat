import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;

import '../models/contact_model.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../screens/chat_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/pin_screen.dart';
import '../services/conversation_storage_service.dart';
import '../services/contact_storage_service.dart';
import '../services/nostr_connection_service.dart';
import '../services/pin_lock_service.dart';
import '../services/secure_key_storage_service.dart';
import '../theme/secure_chat_theme.dart';
import '../widgets/contact_entry_sheet.dart';
import '../widgets/restore_identity_dialog.dart';

class VaultChatRoot extends StatefulWidget {
  const VaultChatRoot({super.key});

  @override
  State<VaultChatRoot> createState() => _VaultChatRootState();
}

class _VaultChatRootState extends State<VaultChatRoot>
    with WidgetsBindingObserver {
  static const List<String> _relayUrls = [
    'wss://relay.damus.io',
    'wss://nos.lol',
  ];

  static const String _lastRecipientStorageKey = 'nostr_last_recipient_hex';

  final Nostr _nostr = Nostr.instance;

  NostrKeyPairs? _keyPair;
  ConversationStorageService? _storageService;
  ContactStorageService? _contactService;
  NostrConnectionService? _connectionService;

  StreamSubscription<SecureChatConnectionSnapshot>? _statusSubscription;
  StreamSubscription<MessageModel>? _incomingMessageSubscription;
  StreamSubscription<RemoteConversationCommand>? _remoteCommandSubscription;
  Timer? _globalExpiryTimer;

  bool _isLoading = true;
  String? _startupError;
  List<ConversationModel> _conversations = <ConversationModel>[];
  Map<String, ContactModel> _contactsByKey = <String, ContactModel>{};

  static const Duration _autoLockAfterBackground = Duration(seconds: 2);
  static const Duration _sensitiveClipboardTtl = Duration(seconds: 90);
  DateTime? _backgroundedAt;
  bool _isNavigatingToLock = false;
  Timer? _clipboardClearTimer;
  String? _lastSensitiveClipboardValue;

  SecureChatConnectionSnapshot _connectionSnapshot =
      SecureChatConnectionSnapshot(
    state: SecureChatConnectionState.idle,
    label: 'Se initializeaza...',
    updatedAt: DateTime.now(),
  );

  String get _publicKey => _keyPair?.public ?? '';
  String get _privateKey => _keyPair?.private ?? '';

  double _premiumDialogWidth(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return min(width - 40, 430).clamp(280, 430).toDouble();
  }

  EdgeInsets _floatingSnackMargin(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return EdgeInsets.fromLTRB(18, 0, 18, 108 + bottomSafe);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      final backgroundedAt = _backgroundedAt;
      _backgroundedAt = null;

      if (backgroundedAt != null &&
          DateTime.now().difference(backgroundedAt) >=
              _autoLockAfterBackground) {
        unawaited(_lockApplicationAfterResume());
        return;
      }

      unawaited(
        _connectionService?.reconnect(
          reason: 'Revenire in aplicatie',
          force: true,
        ),
      );
      unawaited(_purgeExpiredMessagesAndReload());
      unawaited(_reloadConversations());
    }
  }

  Future<void> _lockApplicationAfterResume() async {
    if (!mounted || _isNavigatingToLock) return;

    final hasPin = await PinLockService().hasPin();
    if (!mounted || !hasPin) return;

    _isNavigatingToLock = true;

    await _statusSubscription?.cancel();
    _statusSubscription = null;
    await _incomingMessageSubscription?.cancel();
    _incomingMessageSubscription = null;
    await _remoteCommandSubscription?.cancel();
    _remoteCommandSubscription = null;
    _globalExpiryTimer?.cancel();
    _globalExpiryTimer = null;
    await _connectionService?.dispose();
    _connectionService = null;
    await _storageService?.close();
    _storageService = null;
    await _contactService?.close();
    _contactService = null;

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const PinGate()),
      (_) => false,
    );
  }

  Future<void> _initialize() async {
    try {
      await _loadOrCreateKeys();
      _storageService = await ConversationStorageService.open();
      _contactService = await ContactStorageService.open();
      await _startNostrConnectionService();
      _startGlobalExpiryTimer();
      await _purgeExpiredMessagesAndReload();
      await _reloadConversations();
    } catch (e) {
      _startupError = 'Eroare initializare: $e';
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadOrCreateKeys() async {
    final savedPrivateKey = await SecureKeyStorageService.readPrivateKey();

    if (savedPrivateKey != null && savedPrivateKey.trim().isNotEmpty) {
      _keyPair = _nostr.keys.generateKeyPairFromExistingPrivateKey(
        savedPrivateKey.trim(),
      );
    } else {
      final newPair = _nostr.keys.generateKeyPair();
      await SecureKeyStorageService.writePrivateKey(newPair.private);
      _keyPair = newPair;
    }
  }

  Future<void> _startNostrConnectionService() async {
    final keyPair = _keyPair;
    if (keyPair == null) return;

    final service = NostrConnectionService(
      relayUrls: _relayUrls,
      keyPair: keyPair,
    );

    _connectionService = service;

    _statusSubscription = service.statusStream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _connectionSnapshot = snapshot);
    });

    _incomingMessageSubscription =
        service.messageStream.listen((message) async {
      await _purgeExpiredMessagesAndReload(forceReload: false);
      await _storageService?.saveMessage(message);
      if (!mounted) return;
      await _purgeExpiredMessagesAndReload(forceReload: true);
    });

    _remoteCommandSubscription =
        service.commandStream.listen((command) async {
      if (!command.isDeleteConversation) return;
      await _storageService?.deleteConversationCompletely(
        command.conversationId,
        deletedAt: command.createdAt,
      );
      await _contactService?.deleteContact(command.senderPublicKey);
      if (!mounted) return;
      await _reloadConversations();

      final ageSeconds = DateTime.now()
          .difference(command.createdAt)
          .inSeconds;

      if (ageSeconds <= 8) {
        _showSnackBar('O conversație a fost ștearsă de la distanță.');
      }
    });

    await service.start();
  }

  Future<void> _restartConnectionForCurrentIdentity() async {
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    await _incomingMessageSubscription?.cancel();
    _incomingMessageSubscription = null;
    await _remoteCommandSubscription?.cancel();
    _remoteCommandSubscription = null;
    _globalExpiryTimer?.cancel();
    _globalExpiryTimer = null;
    await _connectionService?.dispose();
    _connectionService = null;

    if (!mounted) return;
    await _startNostrConnectionService();
  }

  Future<void> _reloadConversations() async {
    final storage = _storageService;
    if (storage == null) return;

    final conversations = await storage.loadConversations();
    final contacts = await _contactService?.loadContacts() ?? <ContactModel>[];
    final contactsByKey = <String, ContactModel>{
      for (final contact in contacts) contact.publicKey.toLowerCase(): contact,
    };

    final displayConversations = conversations.map((conversation) {
      final contact = contactsByKey[conversation.peerPublicKey.toLowerCase()];
      final label = contact?.label;
      if (label == null || label.isEmpty) return conversation;
      return conversation.copyWith(peerLabel: label);
    }).toList();

    if (!mounted) return;

    setState(() {
      _contactsByKey = contactsByKey;
      _conversations = displayConversations;
    });
  }

  void _startGlobalExpiryTimer() {
    _globalExpiryTimer?.cancel();
    _globalExpiryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_purgeExpiredMessagesAndReload());
    });
  }

  Future<void> _purgeExpiredMessagesAndReload({bool forceReload = false}) async {
    final storage = _storageService;
    if (storage == null) return;

    final deleted = await storage.deleteExpiredMessages();
    if (!mounted) return;

    if (deleted > 0 || forceReload) {
      await _reloadConversations();
    }
  }

  Future<void> _manualReconnect() async {
    try {
      await _connectionService?.reconnect(reason: 'Manual', force: true);
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Reconectare esuata: $e', isError: true);
    }
  }

  Future<void> _copyMyPublicKey() async {
    if (_publicKey.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _publicKey));
    if (!mounted) return;
    _showSnackBar('ID copiat in clipboard!');
  }

  Future<void> _copySensitiveBackupToClipboard(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _lastSensitiveClipboardValue = value;
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = Timer(_sensitiveClipboardTtl, () async {
      try {
        final current = await Clipboard.getData('text/plain');
        if (current?.text == _lastSensitiveClipboardValue) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {
        // Clipboard clearing is best-effort only.
      } finally {
        _lastSensitiveClipboardValue = null;
      }
    });
  }


  ConversationModel? _findConversationByPeer(String publicKey) {
    final normalized = publicKey.trim().toLowerCase();
    for (final conversation in _conversations) {
      if (conversation.peerPublicKey.trim().toLowerCase() == normalized) {
        return conversation;
      }
    }
    return null;
  }

  Future<void> _openConversation(ConversationModel conversation) async {
    await _openChatWithRecipient(conversation.peerPublicKey);
  }

  Future<void> _openChatWithRecipient(String recipientPublicKey) async {
    final storage = _storageService;
    final connection = _connectionService;
    final keyPair = _keyPair;

    if (storage == null || connection == null || keyPair == null) {
      _showSnackBar('Aplicatia nu este initializata complet.', isError: true);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final normalizedRecipient =
        _extractPublicKey(recipientPublicKey) ?? recipientPublicKey.trim().toLowerCase();

    if (!_isValidPublicKey(normalizedRecipient)) {
      _showSnackBar('ID public invalid. Trebuie să aibă 64 caractere hex.', isError: true);
      return;
    }

    if (normalizedRecipient == keyPair.public.trim().toLowerCase()) {
      _showSnackBar('Nu poți deschide o conversație cu propriul ID.', isError: true);
      return;
    }

    await prefs.setString(_lastRecipientStorageKey, normalizedRecipient);

    final storedContactLabel =
        await _contactService?.displayNameFor(normalizedRecipient);
    final contactLabel = storedContactLabel ??
        _contactsByKey[normalizedRecipient.toLowerCase()]?.label;

    await storage.ensureConversationExists(
      myPublicKey: keyPair.public,
      peerPublicKey: normalizedRecipient,
      peerLabel: contactLabel,
    );
    await _reloadConversations();

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          myPublicKey: keyPair.public,
          recipientPublicKey: normalizedRecipient,
          storageService: storage,
          connectionService: connection,
          contactLabel: contactLabel,
          onConversationChanged: _reloadConversations,
          onConversationDeleted: (peerPublicKey) async {
            await _contactService?.deleteContact(peerPublicKey);
            final prefs = await SharedPreferences.getInstance();
            final lastRecipient = prefs.getString(_lastRecipientStorageKey);
            if (lastRecipient?.trim().toLowerCase() ==
                peerPublicKey.trim().toLowerCase()) {
              await prefs.remove(_lastRecipientStorageKey);
            }
            await _reloadConversations();
          },
        ),
      ),
    );

    if (!mounted) return;
    await _reloadConversations();
  }

  Future<void> _openLastConversationOrNewChat() async {
    final prefs = await SharedPreferences.getInstance();
    final lastRecipient = prefs.getString(_lastRecipientStorageKey);

    if (lastRecipient != null && _isValidPublicKey(lastRecipient)) {
      await _openChatWithRecipient(lastRecipient.trim());
      return;
    }

    if (_conversations.isNotEmpty) {
      await _openConversation(_conversations.first);
      return;
    }

    await _showStartChatDialog();
  }


  Future<bool> _confirmExistingIdentityUpdate({
    required String existingLabel,
    required String requestedLabel,
  }) async {
    final current = existingLabel.trim().isNotEmpty
        ? existingLabel.trim()
        : 'Contact existent';
    final requested = requestedLabel.trim();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('ID deja existent'),
          content: Text(
            requested.isEmpty
                ? 'Acest ID public exista deja in VaultChat. Se va deschide conversatia existenta.'
                : 'Acest ID public exista deja ca "$current". Vrei sa actualizezi numele in "$requested" si sa deschizi conversatia existenta?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(requested.isEmpty ? 'OK' : 'Pastreaza'),
            ),
            if (requested.isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Actualizeaza'),
              ),
          ],
        );
      },
    );

    return result == true;
  }

  Future<void> _showStartChatDialog() async {
    final result = await showModalBottomSheet<ContactDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => const ContactEntrySheet(
        title: 'Conversație nouă',
        subtitle: 'Introdu ID-ul public sau linkul VaultChat al destinatarului.',
        actionLabel: 'Deschide',
        requireName: false,
      ),
    );

    if (!mounted || result == null) return;

    final publicKey = _extractPublicKey(result.publicKeyOrPayload);
    if (publicKey == null) {
      _showSnackBar('ID public invalid. Trebuie să aibă 64 caractere hex.', isError: true);
      return;
    }

    final keyPair = _keyPair;
    if (keyPair != null && publicKey == keyPair.public.trim().toLowerCase()) {
      _showSnackBar('Nu poți crea conversație cu propriul ID.', isError: true);
      return;
    }

    final name = result.displayName.trim();
    final existingConversation = _findConversationByPeer(publicKey);
    final existingContact = _contactsByKey[publicKey];
    final existingLabel = (existingContact?.label.trim().isNotEmpty == true
            ? existingContact!.label
            : existingConversation?.peerLabel)
        ?.trim();
    final alreadyExists = existingConversation != null || existingContact != null;

    if (alreadyExists) {
      final shouldUpdateName = name.isNotEmpty &&
          name != existingLabel &&
          await _confirmExistingIdentityUpdate(
            existingLabel: existingLabel ?? 'Contact existent',
            requestedLabel: name,
          );

      if (shouldUpdateName) {
        await _contactService?.upsertContact(publicKey: publicKey, displayName: name);
      } else if (name.isEmpty) {
        _showSnackBar('Acest ID exista deja. Deschid conversatia existenta.');
      }

      await _reloadConversations();
      if (!mounted) return;
      await _openChatWithRecipient(publicKey);
      return;
    }

    if (name.isNotEmpty) {
      await _contactService?.upsertContact(publicKey: publicKey, displayName: name);
    }

    final storage = _storageService;
    if (keyPair != null && storage != null) {
      await storage.ensureConversationExists(
        myPublicKey: keyPair.public,
        peerPublicKey: publicKey,
        peerLabel: name.isNotEmpty ? name : null,
      );
    }
    await _reloadConversations();

    if (!mounted) return;
    await _openChatWithRecipient(publicKey);
  }

  Future<void> _showAddContactDialog() async {
    final result = await showModalBottomSheet<ContactDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => const ContactEntrySheet(
        title: 'Contact nou',
        subtitle: 'Salvează un nume local pentru un ID public VaultChat.',
        actionLabel: 'Salvează',
        requireName: true,
      ),
    );

    if (!mounted || result == null) return;

    final publicKey = _extractPublicKey(result.publicKeyOrPayload);
    if (publicKey == null) {
      _showSnackBar('ID public invalid. Trebuie să aibă 64 caractere hex.', isError: true);
      return;
    }

    final keyPair = _keyPair;
    if (keyPair != null && publicKey == keyPair.public.trim().toLowerCase()) {
      _showSnackBar('Nu poți salva propriul ID ca destinatar.', isError: true);
      return;
    }

    final name = result.displayName.trim();
    if (name.isEmpty) {
      _showSnackBar('Introdu un nume pentru contact.', isError: true);
      return;
    }

    final existingConversation = _findConversationByPeer(publicKey);
    final existingContact = _contactsByKey[publicKey];
    final alreadyExists = existingConversation != null || existingContact != null;

    if (alreadyExists) {
      final existingLabel = (existingContact?.label.trim().isNotEmpty == true
              ? existingContact!.label
              : existingConversation?.peerLabel)
          ?.trim();
      final shouldUpdateName = await _confirmExistingIdentityUpdate(
        existingLabel: existingLabel ?? 'Contact existent',
        requestedLabel: name,
      );
      if (!shouldUpdateName) {
        await _openChatWithRecipient(publicKey);
        return;
      }
    }

    await _contactService?.upsertContact(publicKey: publicKey, displayName: name);

    final storage = _storageService;
    if (keyPair != null && storage != null) {
      await storage.ensureConversationExists(
        myPublicKey: keyPair.public,
        peerPublicKey: publicKey,
        peerLabel: name,
      );
    }

    await _reloadConversations();
    if (!mounted) return;
    _showSnackBar(alreadyExists ? 'Contact actualizat.' : 'Contact salvat.');
  }


  // ─── BACKUP CRIPTAT IDENTITATE ────────────────────────────────────────

  static const String _identityBackupPrefix = 'VAULTCHAT_BACKUP_V1:';
  static const int _identityBackupIterations = 210000;

  Future<void> _showExportKeyDialog() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    bool obscure = true;

    try {
      final password = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final password = passwordController.text;
              final confirm = confirmController.text;
              final isValid = password.length >= 8 && password == confirm;

              return AlertDialog(
                scrollable: true,
                icon: const Icon(
                  Icons.enhanced_encryption_rounded,
                  color: SecureChatColors.turquoise,
                ),
                title: const Text(
                  'Export identitate criptata',
                  textAlign: TextAlign.center,
                ),
                content: SizedBox(
                  width: _premiumDialogWidth(dialogContext),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Se va crea un backup criptat pentru cheia privata si contactele locale. Salveaza textul generat intr-un loc sigur.',
                      style: TextStyle(fontSize: 13, height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: passwordController,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: 'Parola backup',
                        helperText: 'Min. 8 caractere. Nu este PIN-ul.',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setDialogState(() => obscure = !obscure),
                        ),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: confirmController,
                      obscureText: obscure,
                      decoration: const InputDecoration(
                        labelText: 'Confirma parola backup',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: SecureChatColors.warning.withValues(alpha: 0.10),
                        border: Border.all(
                          color: SecureChatColors.warning.withValues(alpha: 0.32),
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Daca pierzi parola backupului, cheia privata nu poate fi recuperata.',
                        style: TextStyle(
                          fontSize: 12,
                          color: SecureChatColors.warning,
                          height: 1.35,
                        ),
                      ),
                    ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Anuleaza'),
                  ),
                  FilledButton.icon(
                    onPressed: isValid
                        ? () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            Navigator.of(dialogContext, rootNavigator: true).pop(password);
                          }
                        : null,
                    icon: const Icon(Icons.lock_rounded),
                    label: const Text('Genereaza backup'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (password == null || password.isEmpty) return;

      // Let the password dialog finish disposing before generating and opening
      // the next route. This avoids Flutter overlay/focus assertion failures
      // on some Android builds when the keyboard is still active.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;

      try {
        final backupText = await _createEncryptedIdentityBackup(password);
        if (!mounted) return;
        await Clipboard.setData(ClipboardData(text: backupText));
        if (!mounted) return;
        await _showEncryptedBackupResultDialog(backupText);
      } catch (e) {
        if (!mounted) return;
        _showSnackBar('Nu s-a putut genera backupul: $e', isError: true);
      }
    } finally {
      passwordController.dispose();
      confirmController.dispose();
    }
  }

  Future<String> _createEncryptedIdentityBackup(String password) async {
    final privateKey = _privateKey.trim();
    final publicKey = _publicKey.trim().toLowerCase();
    if (!_isValidPrivateKey(privateKey) || !_isValidPublicKey(publicKey)) {
      throw StateError('Identitatea curenta nu este valida pentru export.');
    }

    final contacts = await _contactService?.loadContacts() ?? <ContactModel>[];
    final storageSnapshot = await _storageService?.exportBackupSnapshot(
          myPublicKey: publicKey,
        ) ??
        const <String, dynamic>{
          'schema': 1,
          'messages': <Map<String, dynamic>>[],
          'conversations': <Map<String, dynamic>>[],
        };

    final plaintextMap = <String, dynamic>{
      'type': 'vaultchat_identity',
      'version': 3,
      'createdAt': DateTime.now().toIso8601String(),
      'publicKey': publicKey,
      'privateKey': privateKey,
      'contacts': contacts.map((contact) => contact.toMap()).toList(),
      'storage': storageSnapshot,
    };

    final plaintext = utf8.encode(jsonEncode(plaintextMap));
    final salt = _secureRandomBytes(16);
    final nonce = _secureRandomBytes(12);
    final secretKey = await _deriveBackupSecretKey(
      password,
      salt,
      _identityBackupIterations,
    );
    final algorithm = cryptography.AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    final container = <String, dynamic>{
      'type': 'vaultchat_encrypted_identity_backup',
      'version': 2,
      'algorithm': 'aes-256-gcm',
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': _identityBackupIterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(secretBox.nonce),
      'cipher': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
      'createdAt': DateTime.now().toIso8601String(),
      'publicKeyHint': publicKey.substring(0, 8),
    };

    return '$_identityBackupPrefix${base64Encode(utf8.encode(jsonEncode(container)))}';
  }

  Future<void> _showEncryptedBackupResultDialog(String backupText) async {
    final backupTextController = TextEditingController(text: backupText);

    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.security_rounded, color: SecureChatColors.turquoise),
          title: const Text('Backup criptat generat', textAlign: TextAlign.center),
          content: SizedBox(
            width: _premiumDialogWidth(ctx),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Backupul a fost copiat automat in clipboard pentru 90 secunde. Copiaza-l intr-un loc offline sigur. Pentru restaurare vei avea nevoie de parola backupului.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: backupTextController,
                readOnly: true,
                maxLines: 5,
                minLines: 3,
                style: const TextStyle(fontSize: 9.5, height: 1.22, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'Backup criptat VaultChat',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Copiaza',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: backupText));
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Backup copiat temporar in clipboard.')),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: SecureChatColors.warning.withValues(alpha: 0.10),
                  border: Border.all(color: SecureChatColors.warning.withValues(alpha: 0.28)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Nu trimite acest backup altor persoane. Clipboard-ul va fi curatat automat dupa 90 secunde, daca textul nu a fost inlocuit de altceva.',
                  style: TextStyle(
                    fontSize: 12,
                    color: SecureChatColors.warning,
                    height: 1.35,
                  ),
                ),
              ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Inchide'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: backupText));
                if (!ctx.mounted) return;
                Navigator.of(ctx, rootNavigator: true).pop();
                if (!mounted) return;
                _showSnackBar('Backup criptat copiat temporar in clipboard. Salveaza-l offline.');
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copiaza si inchide'),
            ),
          ],
        ),
      );
    } finally {
      backupTextController.dispose();
    }
  }

  // ─── IMPORT BACKUP CRIPTAT / RESTORE IDENTITATE ────────────────────────────

  Future<void> _showRestoreKeyDialog() async {
    final result = await showDialog<IdentityRestoreRequest>(
      context: context,
      builder: (dialogContext) => RestoreIdentityDialog(
        identityBackupPrefix: _identityBackupPrefix,
        dialogWidth: _premiumDialogWidth(dialogContext),
        isValidPrivateKey: _isValidPrivateKey,
      ),
    );

    if (result == null) return;

    // Wait for the restore dialog, keyboard and focus tree to dispose cleanly
    // before mutating app identity/storage. This prevents Flutter
    // `_dependents.isEmpty` assertion crashes on Android after paste/restore.
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;

    await _restoreIdentityFromPayload(result.payload, result.password);
  }

  Future<void> _restoreIdentityFromPayload(String payload, String password) async {
    try {
      final cleanPayload = normalizeVaultChatRestorePayload(payload);
      if (_isValidPrivateKey(cleanPayload)) {
        await _restorePrivateKey(cleanPayload);
        return;
      }

      final restored = await _decryptIdentityBackup(cleanPayload, password);
      await _restorePrivateKey(
        restored.privateKey,
        restoredContacts: restored.contacts,
        restoredMessages: restored.messages,
        restoredConversations: restored.conversations,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Backup invalid sau parola gresita.', isError: true);
    }
  }

  Future<RestoredIdentityBackup> _decryptIdentityBackup(
    String backupText,
    String password,
  ) async {
    if (!backupText.startsWith(_identityBackupPrefix)) {
      throw const FormatException('Prefix invalid');
    }

    final encoded = backupText.substring(_identityBackupPrefix.length).trim();
    final containerText = utf8.decode(base64Decode(encoded));
    final container = jsonDecode(containerText);
    if (container is! Map) throw const FormatException('Container invalid');

    final version = (container['version'] as num?)?.toInt();
    if (version == 2) {
      return _decryptIdentityBackupV2(container, password);
    }
    if (version == 1) {
      return _decryptIdentityBackupV1Legacy(container, password);
    }

    throw const FormatException('Versiune backup nesuportata');
  }

  Future<RestoredIdentityBackup> _decryptIdentityBackupV2(
    Map container,
    String password,
  ) async {
    final iterations =
        (container['iterations'] as num?)?.toInt() ?? _identityBackupIterations;
    final salt = base64Decode(container['salt'] as String);
    final nonce = base64Decode(container['nonce'] as String);
    final cipherBytes = base64Decode(container['cipher'] as String);
    final macBytes = base64Decode(container['mac'] as String);

    final secretKey = await _deriveBackupSecretKey(password, salt, iterations);
    final algorithm = cryptography.AesGcm.with256bits();
    final plainBytes = await algorithm.decrypt(
      cryptography.SecretBox(
        cipherBytes,
        nonce: nonce,
        mac: cryptography.Mac(macBytes),
      ),
      secretKey: secretKey,
    );

    return _parseRestoredIdentityPlaintext(plainBytes);
  }

  RestoredIdentityBackup _decryptIdentityBackupV1Legacy(
    Map container,
    String password,
  ) {
    final iterations =
        (container['iterations'] as num?)?.toInt() ?? _identityBackupIterations;
    final salt = base64Decode(container['salt'] as String);
    final nonce = base64Decode(container['nonce'] as String);
    final cipherBytes = base64Decode(container['cipher'] as String);
    final expectedMac = base64Decode(container['mac'] as String);

    final key = _deriveBackupKeyLegacy(password, salt, iterations);
    final actualMac = _backupMacLegacy(key, nonce, cipherBytes);
    if (!_constantTimeEquals(expectedMac, actualMac)) {
      throw const FormatException('MAC invalid');
    }

    final plainBytes = _xorWithKeyStreamLegacy(cipherBytes, key, nonce);
    return _parseRestoredIdentityPlaintext(plainBytes);
  }

  RestoredIdentityBackup _parseRestoredIdentityPlaintext(List<int> plainBytes) {
    final plain = jsonDecode(utf8.decode(plainBytes));
    if (plain is! Map) throw const FormatException('Plaintext invalid');

    final privateKey = (plain['privateKey'] ?? '').toString().trim();
    final publicKey = (plain['publicKey'] ?? '').toString().trim().toLowerCase();
    if (!_isValidPrivateKey(privateKey) || !_isValidPublicKey(publicKey)) {
      throw const FormatException('Chei invalide');
    }

    final contactsRaw = plain['contacts'];
    final contacts = <ContactModel>[];
    if (contactsRaw is List) {
      for (final item in contactsRaw) {
        if (item is Map) {
          final contact = ContactModel.fromMap(item);
          if (contact.publicKey.trim().isNotEmpty &&
              contact.displayName.trim().isNotEmpty) {
            contacts.add(contact);
          }
        }
      }
    }

    final restoredMessages = <MessageModel>[];
    final restoredConversations = <ConversationModel>[];
    final storageRaw = plain['storage'];
    if (storageRaw is Map) {
      final messagesRaw = storageRaw['messages'];
      if (messagesRaw is List) {
        for (final item in messagesRaw) {
          if (item is Map) {
            final message = MessageModel.fromMap(item);
            if (message.id.trim().isNotEmpty &&
                message.text.trim().isNotEmpty &&
                message.senderPublicKey.trim().isNotEmpty &&
                message.recipientPublicKey.trim().isNotEmpty) {
              restoredMessages.add(message);
            }
          }
        }
      }

      final conversationsRaw = storageRaw['conversations'];
      if (conversationsRaw is List) {
        for (final item in conversationsRaw) {
          if (item is Map) {
            final conversation = ConversationModel.fromMap(item);
            if (conversation.id.trim().isNotEmpty &&
                conversation.myPublicKey.trim().isNotEmpty &&
                conversation.peerPublicKey.trim().isNotEmpty) {
              restoredConversations.add(conversation);
            }
          }
        }
      }
    }

    return RestoredIdentityBackup(
      privateKey: privateKey,
      contacts: contacts,
      messages: restoredMessages,
      conversations: restoredConversations,
    );
  }

  Future<void> _restorePrivateKey(
    String privateKey, {
    List<ContactModel> restoredContacts = const <ContactModel>[],
    List<MessageModel> restoredMessages = const <MessageModel>[],
    List<ConversationModel> restoredConversations = const <ConversationModel>[],
  }) async {
    try {
      final restoredPair = _nostr.keys
          .generateKeyPairFromExistingPrivateKey(privateKey.trim());

      if (restoredPair.public.isEmpty) {
        _showSnackBar('Cheie invalida — nu s-a putut restaura.', isError: true);
        return;
      }

      await SecureKeyStorageService.writePrivateKey(privateKey.trim());

      _keyPair = restoredPair;

      if (restoredContacts.isNotEmpty) {
        _contactService ??= await ContactStorageService.open();
        for (final contact in restoredContacts) {
          await _contactService?.upsertContact(
            publicKey: contact.publicKey,
            displayName: contact.displayName,
          );
        }
      }

      if (restoredMessages.isNotEmpty || restoredConversations.isNotEmpty) {
        // Warn user that existing messages and deleted-conversation records
        // will be replaced. This prevents a surprise when an old backup is
        // restored on an active device and previously-deleted conversations
        // reappear (tombstones are cleared together with all local data).
        if (!mounted) return;
        final confirmRestore = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            scrollable: true,
            backgroundColor: SecureChatColors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SecureChatRadius.xl),
            ),
            icon: const Icon(Icons.warning_amber_rounded,
                color: SecureChatColors.warning),
            title: const Text(
              'Înlocuiești conversațiile existente?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: SecureChatColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
            content: const Text(
              'Backupul conține mesaje. Restaurarea va șterge complet '
              'toate conversațiile și mesajele existente pe acest dispozitiv, '
              'inclusiv cele șterse anterior.\n\n'
              'Acțiunea este ireversibilă.',
              style: TextStyle(
                color: SecureChatColors.mutedText,
                height: 1.4,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Anulează'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: SecureChatColors.warning,
                  foregroundColor: Colors.black87,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Înlocuiește'),
              ),
            ],
          ),
        );

        if (confirmRestore != true) return;

        _storageService ??= await ConversationStorageService.open();
        await _storageService?.restoreBackupSnapshot(
          messages: restoredMessages,
          conversations: restoredConversations,
          replaceExisting: true,
        );
      }

      await _restartConnectionForCurrentIdentity();
      await _reloadConversations();

      if (!mounted) return;

      await Future<void>.delayed(const Duration(milliseconds: 250));

      if (!mounted) return;

      _showSnackBar(
        restoredMessages.isNotEmpty
            ? 'Identitate, contacte si mesaje restaurate cu succes.'
            : restoredContacts.isEmpty
                ? 'Identitate restaurata si reconectata cu succes.'
                : 'Identitate si contacte restaurate cu succes.',
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Cheie invalida: $e', isError: true);
    }
  }

  List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<cryptography.SecretKey> _deriveBackupSecretKey(
    String password,
    List<int> salt,
    int iterations,
  ) {
    final pbkdf2 = cryptography.Pbkdf2(
      macAlgorithm: cryptography.Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );

    return pbkdf2.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  List<int> _deriveBackupKeyLegacy(String password, List<int> salt, int iterations) {
    final passwordBytes = utf8.encode(password);
    final hmac = Hmac(sha256, passwordBytes);
    final blockIndex = <int>[0, 0, 0, 1];
    var u = hmac.convert(<int>[...salt, ...blockIndex]).bytes;
    final output = List<int>.from(u);

    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < output.length; j++) {
        output[j] ^= u[j];
      }
    }

    return output;
  }

  List<int> _xorWithKeyStreamLegacy(List<int> input, List<int> key, List<int> nonce) {
    final output = <int>[];
    var counter = 0;

    while (output.length < input.length) {
      final counterBytes = <int>[
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ];
      final stream = Hmac(sha256, key).convert(<int>[...nonce, ...counterBytes]).bytes;
      for (final byte in stream) {
        if (output.length >= input.length) break;
        output.add(input[output.length] ^ byte);
      }
      counter++;
    }

    return output;
  }

  List<int> _backupMacLegacy(List<int> key, List<int> nonce, List<int> cipherBytes) {
    return Hmac(sha256, key).convert(<int>[
      ...utf8.encode('vaultchat-backup-v1'),
      ...nonce,
      ...cipherBytes,
    ]).bytes;
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ─── DIALOG IDENTITATE (cu toate optiunile) ────────────────────────────────

  void _showKeysDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.key_rounded, color: SecureChatColors.violetSoft),
        title: const Text('Identitatea ta', textAlign: TextAlign.center),
        content: SizedBox(
          width: _premiumDialogWidth(ctx),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Cheie publica ──
            const Text(
              'ID-ul tau public (shareaza-l cu ceilalti):',
              style: TextStyle(fontSize: 12, color: SecureChatColors.mutedText),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: SecureChatColors.cardAlt.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _publicKey,
                style: const TextStyle(fontSize: 10.5, height: 1.25, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _copyMyPublicKey();
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copiaza ID-ul meu'),
              ),
            ),

            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final payload = _vaultContactPayload(_publicKey);
                  await Clipboard.setData(ClipboardData(text: payload));
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  if (!mounted) return;
                  _showSnackBar('Link VaultChat copiat. Poate fi lipit la Contact nou.');
                },
                icon: const Icon(Icons.qr_code_2_rounded),
                label: const Text('Copiaza link VaultChat'),
              ),
            ),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // ── Backup ──
            const Text(
              'Backup & Restore identitate:',
              style: TextStyle(fontSize: 12, color: SecureChatColors.mutedText),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: SecureChatColors.danger,
                  side: BorderSide(color: SecureChatColors.danger.withValues(alpha: 0.55)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _showExportKeyDialog();
                },
                icon: const Icon(Icons.download),
                label: const Text('Exporta backup criptat'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showRestoreKeyDialog();
                },
                icon: const Icon(Icons.restore),
                label: const Text('Restaureaza identitatea'),
              ),
            ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Inchide'),
          ),
        ],
      ),
    );
  }

  // ─── HELPERS ───────────────────────────────────────────────────────────────


  static String _vaultContactPayload(String publicKey) {
    return 'vaultchat://contact?pubkey=${publicKey.trim().toLowerCase()}';
  }

  static String? _extractPublicKey(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;

    final uri = Uri.tryParse(raw);
    final queryKey = uri?.queryParameters['pubkey'];
    if (queryKey != null && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(queryKey.trim())) {
      return queryKey.trim().toLowerCase();
    }

    final match = RegExp(r'[a-fA-F0-9]{64}').firstMatch(raw);
    if (match == null) return null;
    return match.group(0)!.toLowerCase();
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: isError ? SecureChatColors.danger : SecureChatColors.cardAlt,
        behavior: SnackBarBehavior.floating,
        margin: _floatingSnackMargin(context),
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
  }

  bool _isValidPublicKey(String value) {
    return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value.trim());
  }

  bool _isValidPrivateKey(String value) {
    // Cheile private Nostr sunt tot hex de 64 caractere
    return RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value.trim());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSubscription?.cancel();
    _incomingMessageSubscription?.cancel();
    _remoteCommandSubscription?.cancel();
    _globalExpiryTimer?.cancel();
    _clipboardClearTimer?.cancel();
    unawaited(_connectionService?.dispose());
    unawaited(_storageService?.close());
    unawaited(_contactService?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_startupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('VaultChat 🔒')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _startupError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: SecureChatColors.danger),
            ),
          ),
        ),
      );
    }

    return InboxScreen(
      conversations: _conversations,
      connectionSnapshot: _connectionSnapshot,
      myPublicKey: _publicKey,
      onOpenConversation: _openConversation,
      onNewConversation: _showStartChatDialog,
      onAddContact: _showAddContactDialog,
      onManualReconnect: _manualReconnect,
      onShowKeys: _showKeysDialog,
      onOpenLastConversation: _openLastConversationOrNewChat,
    );
  }
}
