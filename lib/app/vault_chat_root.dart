import 'dart:async';
import 'dart:math';

import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../auth/pin_gate.dart';
import '../models/conversation_model.dart';
import '../screens/chat_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/qr_scan_screen.dart';
import '../services/identity_backup_service.dart';
import '../theme/secure_chat_theme.dart';
import '../widgets/contact_entry_sheet.dart';
import 'app_controller.dart';

/// Root widget al aplicației — exclusiv UI.
/// Toată logica de business este delegată către [AppController].
class VaultChatRoot extends StatefulWidget {
  const VaultChatRoot({super.key});

  @override
  State<VaultChatRoot> createState() => _VaultChatRootState();
}

class _VaultChatRootState extends State<VaultChatRoot>
    with WidgetsBindingObserver {

  AppController? _ctrl;
  StreamSubscription<AppState>? _stateSub;
  AppState _appState = AppState.initial();

  DateTime? _backgroundedAt;
  bool _isNavigatingToLock = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    final ctrl = await AppController.create();
    if (!mounted) { await ctrl.dispose(); return; }
    _ctrl = ctrl;
    _stateSub = ctrl.stateStream.listen((s) {
      if (mounted) setState(() => _appState = s);
    });
    setState(() => _appState = ctrl.state);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _ctrl;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed && ctrl != null) {
      final bg = _backgroundedAt;
      _backgroundedAt = null;
      if (ctrl.shouldLock(bg)) {
        _lockApp();
      } else {
        unawaited(ctrl.reconnectAfterResume());
      }
    }
  }

  void _lockApp() {
    if (!mounted || _isNavigatingToLock) return;
    _isNavigatingToLock = true;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const PinGate()),
      (_) => false,
    ).then((_) => _isNavigatingToLock = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stateSub?.cancel();
    unawaited(_ctrl?.dispose());
    super.dispose();
  }

  // ── Navigation helpers ────────────────────────────────────────────────────

  Future<void> _openConversation(ConversationModel conv) =>
      _openChatWith(conv.peerPublicKey);

  Future<void> _openChatWith(String peerPublicKey) async {
    final ctrl = _ctrl;
    if (ctrl == null || !mounted) return;

    final storage = ctrl.storageService;
    final connection = ctrl.connectionService;
    if (storage == null || connection == null) return;

    final state = _appState;
    final contact = state.contactsByKey[peerPublicKey.toLowerCase()];
    final label = contact?.label.isNotEmpty == true
        ? contact!.label
        : state.conversations
                .where((c) => c.peerPublicKey == peerPublicKey)
                .firstOrNull
                ?.peerLabel ??
            peerPublicKey.substring(0, 8);

    await ctrl.setLastRecipient(peerPublicKey);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          recipientPublicKey: peerPublicKey,
          myPublicKey: state.publicKey,
          peerLabel: label,
          storageService: storage,
          connectionService: connection,
          onConversationChanged: ctrl.reloadConversations,
          onConversationDeleted: (_) async {
            await ctrl.reloadConversations();
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
    await ctrl.reloadConversations();
  }

  Future<void> _openLastOrNew() async {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    final last = await ctrl.lastRecipient();
    if (last != null && last.isNotEmpty) {
      await _openChatWith(last);
    } else {
      await _showStartChatDialog();
    }
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────

  Future<void> _showStartChatDialog() async {
    if (!mounted) return;
    final result = await showModalBottomSheet<ContactDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ContactEntrySheet(
        title: 'New conversation',
        subtitle: 'Enter the recipient public ID or VaultChat link.',
        actionLabel: 'Deschide',
        requireName: false,
      ),
    );
    if (!mounted || result == null) return;

    final publicKey = IdentityBackupService.extractPublicKey(result.publicKeyOrPayload);
    if (publicKey == null) {
      _snack('Invalid public ID. It must be 64 hex characters.', error: true);
      return;
    }
    if (publicKey == _appState.publicKey.toLowerCase()) {
      _snack('You cannot create a conversation with your own ID.', error: true);
      return;
    }

    final ctrl = _ctrl!;
    if (result.displayName.isNotEmpty) {
      await ctrl.upsertContact(publicKey: publicKey, displayName: result.displayName);
    }

    final storage = ctrl.storageService;
    if (storage != null) {
      await storage.ensureConversationExists(
        myPublicKey: _appState.publicKey,
        peerPublicKey: publicKey,
        peerLabel: result.displayName.isNotEmpty ? result.displayName : null,
      );
    }
    await ctrl.reloadConversations();
    if (!mounted) return;
    await _openChatWith(publicKey);
  }

  Future<void> _showAddContactDialog() async {
    if (!mounted) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      backgroundColor: SecureChatColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: SecureChatColors.borderSoft.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Add contact',
                  style: TextStyle(
                    color: SecureChatColors.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scan the VaultChat QR code or enter the public key manually.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: SecureChatColors.mutedText,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                ListTile(
                  leading: const Icon(
                    Icons.qr_code_scanner_rounded,
                    color: SecureChatColors.turquoise,
                  ),
                  title: const Text(
                    'Scan QR',
                    style: TextStyle(
                      color: SecureChatColors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: const Text(
                    'Scan the code from the other phone.',
                    style: TextStyle(color: SecureChatColors.mutedText),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('scan'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.keyboard_rounded,
                    color: SecureChatColors.violetSoft,
                  ),
                  title: const Text(
                    'Enter manually',
                    style: TextStyle(
                      color: SecureChatColors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: const Text(
                    'Paste the public key or VaultChat link.',
                    style: TextStyle(color: SecureChatColors.mutedText),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('manual'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;

    if (action == 'scan') {
      await _scanAndAddContact();
      return;
    }

    await _showManualAddContactDialog();
  }

  Future<void> _showManualAddContactDialog() async {
    if (!mounted) return;

    final result = await showModalBottomSheet<ContactDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ContactEntrySheet(
        title: 'Add contact',
        subtitle: 'Enter the Nostr public ID and a contact name.',
        actionLabel: 'Save',
        requireName: true,
      ),
    );

    if (!mounted || result == null) return;

    final publicKey = IdentityBackupService.extractPublicKey(result.publicKeyOrPayload);
    if (publicKey == null) {
      _snack('Invalid ID.', error: true);
      return;
    }

    if (publicKey == _appState.publicKey.toLowerCase()) {
      _snack('You cannot add your own ID as a recipient.', error: true);
      return;
    }

    await _saveScannedOrManualContact(
      publicKey: publicKey,
      displayName: result.displayName,
      openChatAfterSave: false,
    );
  }

  Future<void> _scanAndAddContact() async {
    final rawValue = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScanScreen(),
      ),
    );

    if (!mounted || rawValue == null || rawValue.trim().isEmpty) return;

    // Lăsăm ruta camerei să se închidă complet înainte de a deschide
    // dialogul de nume. Fără acest mic delay, pe unele telefoane apare
    // assertion Flutter `_dependents.isEmpty` după scanare.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;

    final publicKey = IdentityBackupService.extractPublicKey(rawValue);
    if (publicKey == null) {
      _snack('Invalid QR. It does not contain a valid VaultChat key.', error: true);
      return;
    }

    if (publicKey == _appState.publicKey.toLowerCase()) {
      _snack('This is your own QR code.', error: true);
      return;
    }

    final displayName = await _askContactNameForScannedKey(publicKey);
    if (!mounted || displayName == null) return;

    await _saveScannedOrManualContact(
      publicKey: publicKey,
      displayName: displayName,
      openChatAfterSave: false,
    );
  }

  Future<String?> _askContactNameForScannedKey(String publicKey) async {
    final controller = TextEditingController();

    String? result;
    try {
      result = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) {
          return AlertDialog(
            scrollable: true,
            icon: const Icon(
              Icons.qr_code_scanner_rounded,
              color: SecureChatColors.turquoise,
            ),
            title: const Text(
              'VaultChat QR detected',
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: _dialogWidth(dialogContext),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose a local name for this contact.',
                    style: TextStyle(fontSize: 13, height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: false,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Contact name',
                      hintText: 'e.g. Alice',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      final name = controller.text.trim();
                      Navigator.of(dialogContext, rootNavigator: true).pop(
                        name.isEmpty ? publicKey.substring(0, 8) : name,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    publicKey,
                    style: const TextStyle(
                      color: SecureChatColors.mutedText,
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  Navigator.of(dialogContext, rootNavigator: true).pop();
                },
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  final name = controller.text.trim();
                  Navigator.of(dialogContext, rootNavigator: true).pop(
                    name.isEmpty ? publicKey.substring(0, 8) : name,
                  );
                },
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save'),
              ),
            ],
          );
        },
      );
      // Lăsăm dialogul și focus tree-ul să se demonteze complet înainte
      // de dispose/navigare. Evită crash-ul `_dependents.isEmpty` pe Android.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      return result;
    } finally {
      controller.dispose();
    }
  }

  Future<void> _saveScannedOrManualContact({
    required String publicKey,
    required String displayName,
    required bool openChatAfterSave,
  }) async {
    final ctrl = _ctrl;
    if (ctrl == null) return;

    final cleanName = displayName.trim().isEmpty
        ? publicKey.substring(0, 8)
        : displayName.trim();

    await ctrl.upsertContact(publicKey: publicKey, displayName: cleanName);

    final storage = ctrl.storageService;
    if (storage != null) {
      await storage.ensureConversationExists(
        myPublicKey: _appState.publicKey,
        peerPublicKey: publicKey,
        peerLabel: cleanName,
      );
    }

    await ctrl.reloadConversations();

    if (!mounted) return;
    _snack(
      openChatAfterSave
          ? 'Contact saved.'
          : 'Contact saved. Tap the contact in the list to open the chat.',
    );

    if (openChatAfterSave) {
      // Deschiderea automată se păstrează doar pentru fluxurile manuale unde
      // ruta camerei nu este implicată. Pentru QR scan rămânem în Inbox.
      await Future<void>.delayed(const Duration(milliseconds: 420));
      if (!mounted) return;
      await _openChatWith(publicKey);
    }
  }

  Future<void> _showQrDialog(String publicKey) async {
    final pub = publicKey.trim().toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pub)) {
      _snack('Invalid public ID.', error: true);
      return;
    }

    final link = IdentityBackupService.vaultContactPayload(pub);

    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
          child: Material(
            color: SecureChatColors.card,
            borderRadius: BorderRadius.circular(26),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: _dialogWidth(dialogContext),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.qr_code_2_rounded,
                      color: SecureChatColors.turquoise,
                      size: 38,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'My QR code',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: SecureChatColors.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Scan this code from another phone to add the contact.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: SecureChatColors.mutedText,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: SizedBox(
                        width: 230,
                        height: 230,
                        child: QrImageView(
                          data: link,
                          version: QrVersions.auto,
                          size: 230,
                          gapless: true,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black,
                          ),
                          errorStateBuilder: (context, error) {
                            return const Center(
                              child: Text(
                                'QR unavailable',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      link,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: SecureChatColors.mutedText,
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.of(
                              dialogContext,
                              rootNavigator: true,
                            ).pop(),
                            child: const Text('Close'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: link));
                              if (!dialogContext.mounted) return;
                              Navigator.of(dialogContext, rootNavigator: true).pop();
                              _snack('VaultChat link copied.');
                            },
                            icon: const Icon(Icons.copy_rounded),
                            label: const Text('Copy'),
                          ),
                        ),
                      ],
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

  void _showKeysDialog() {
    final pub = _appState.publicKey;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.key_rounded, color: SecureChatColors.violetSoft),
        title: const Text('Your identity', textAlign: TextAlign.center),
        content: SizedBox(
          width: _dialogWidth(ctx),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your public ID (share it with others):',
                  style: TextStyle(fontSize: 12, color: SecureChatColors.mutedText)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: SecureChatColors.cardAlt.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(pub,
                    style: const TextStyle(fontSize: 10.5, height: 1.25)),
              ),
              const SizedBox(height: 10),
              _fullBtn(FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _ctrl?.copyPublicKey(context);
                  _snack('Public ID copied.');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy my ID'),
              )),
              const SizedBox(height: 8),
              _fullBtn(OutlinedButton.icon(
                onPressed: () async {
                  Navigator.of(ctx, rootNavigator: true).pop();
                  await Future<void>.delayed(const Duration(milliseconds: 260));
                  if (!mounted) return;
                  await _showQrDialog(pub);
                },
                icon: const Icon(Icons.qr_code_2_rounded),
                label: const Text('Show my QR'),
              )),
              const SizedBox(height: 8),
              _fullBtn(OutlinedButton.icon(
                onPressed: () async {
                  final link = IdentityBackupService.vaultContactPayload(pub);
                  await Clipboard.setData(ClipboardData(text: link));
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  _snack('VaultChat link copied.');
                },
                icon: const Icon(Icons.link_rounded),
                label: const Text('Copy VaultChat link'),
              )),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Backup & Restore:',
                  style: TextStyle(fontSize: 12, color: SecureChatColors.mutedText)),
              const SizedBox(height: 8),
              _fullBtn(OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: SecureChatColors.danger,
                  side: BorderSide(color: SecureChatColors.danger.withValues(alpha: 0.55)),
                ),
                onPressed: () { Navigator.pop(ctx); _showExportDialog(); },
                icon: const Icon(Icons.download),
                label: const Text('Export encrypted backup'),
              )),
              const SizedBox(height: 8),
              _fullBtn(OutlinedButton.icon(
                onPressed: () { Navigator.pop(ctx); _showRestoreDialog(); },
                icon: const Icon(Icons.restore),
                label: const Text('Restore identity'),
              )),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _showExportDialog() async {
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool obscure = true;

    try {
      final password = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (context, setS) {
            final isValid = passwordCtrl.text.length >= 8 &&
                passwordCtrl.text == confirmCtrl.text;
            return AlertDialog(
              scrollable: true,
              icon: const Icon(Icons.enhanced_encryption_rounded,
                  color: SecureChatColors.turquoise),
              title: const Text('Encrypted identity export', textAlign: TextAlign.center),
              content: SizedBox(
                width: _dialogWidth(ctx),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                    'An AES-GCM-256 encrypted backup of your private key and contacts will be created. '
                    'Save the generated text in a safe place.',
                    style: TextStyle(fontSize: 13, height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordCtrl,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Backup password',
                      helperText: 'Min. 8 characters.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setS(() => obscure = !obscure),
                      ),
                    ),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: obscure,
                    decoration: const InputDecoration(
                        labelText: 'Confirm password', border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 10),
                  _warningBox('If you lose the backup password, the private key cannot be recovered.'),
                ]),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton.icon(
                  onPressed: isValid
                      ? () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.of(ctx, rootNavigator: true).pop(passwordCtrl.text);
                        }
                      : null,
                  icon: const Icon(Icons.lock_rounded),
                  label: const Text('Generate backup'),
                ),
              ],
            );
          },
        ),
      );

      if (password == null || password.isEmpty || !mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;

      try {
        final backup = await _ctrl!.createBackup(password);
        if (!mounted) return;
        await _ctrl!.copySensitive(backup);
        _showBackupResultDialog(backup);
      } catch (e) {
        _snack('Could not generate backup: $e', error: true);
      }
    } finally {
      passwordCtrl.dispose();
      confirmCtrl.dispose();
    }
  }

  void _showBackupResultDialog(String backupText) {
    final ctrl = TextEditingController(text: backupText);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_rounded, color: SecureChatColors.turquoise),
        title: const Text('Backup generated', textAlign: TextAlign.center),
        content: SizedBox(
          width: _dialogWidth(ctx),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('The backup was copied to the clipboard (clears automatically in 90s). '
                'Save the text below in a safe place.'),
            const SizedBox(height: 12),
            TextField(controller: ctrl, maxLines: 4, readOnly: true,
                decoration: const InputDecoration(border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          FilledButton.icon(
            onPressed: () async {
              await _ctrl?.copySensitive(backupText);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy again'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  Future<void> _showRestoreDialog() async {
    final payloadCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.restore_rounded, color: SecureChatColors.violetBright),
          title: const Text('Restore identity', textAlign: TextAlign.center),
          content: SizedBox(
            width: _dialogWidth(ctx),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _warningBox('This will replace the current identity. Make sure you have a backup.'),
              const SizedBox(height: 12),
              TextField(
                controller: payloadCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                    labelText: 'Backup or hex private key',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Backup password (if any)',
                    border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.restore),
              label: const Text('Restore'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;

      try {
        await _ctrl!.restoreFromBackup(payloadCtrl.text, passwordCtrl.text);
        _snack('Identity restored successfully.');
      } catch (e) {
        _snack('Invalid backup or wrong password.', error: true);
      }
    } finally {
      payloadCtrl.dispose();
      passwordCtrl.dispose();
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  double _dialogWidth(BuildContext ctx) {
    final w = MediaQuery.of(ctx).size.width;
    return min(w - 40, 430).clamp(280, 430).toDouble();
  }

  Widget _fullBtn(Widget btn) => SizedBox(width: double.infinity, child: btn);

  Widget _warningBox(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: SecureChatColors.warning.withValues(alpha: 0.10),
          border: Border.all(color: SecureChatColors.warning.withValues(alpha: 0.32)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12, color: SecureChatColors.warning, height: 1.35)),
      );

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w700)),
      backgroundColor: error ? SecureChatColors.danger : SecureChatColors.cardAlt,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(18, 0, 18,
          108 + MediaQuery.of(context).padding.bottom),
      duration: Duration(seconds: error ? 5 : 3),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_appState.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_appState.startupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('VaultChat 🔒')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_appState.startupError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: SecureChatColors.danger)),
          ),
        ),
      );
    }

    return InboxScreen(
      conversations: _appState.conversations,
      connectionSnapshot: _appState.connectionSnapshot,
      myPublicKey: _appState.publicKey,
      onOpenConversation: _openConversation,
      onNewConversation: _showStartChatDialog,
      onAddContact: _showAddContactDialog,
      onManualReconnect: () => _ctrl?.manualReconnect(),
      onShowKeys: _showKeysDialog,
      onOpenLastConversation: _openLastOrNew,
    );
  }
}
