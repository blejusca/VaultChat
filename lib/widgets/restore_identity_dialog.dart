import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/contact_model.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../theme/secure_chat_theme.dart';

class IdentityRestoreRequest {
  const IdentityRestoreRequest({
    required this.payload,
    required this.password,
  });

  final String payload;
  final String password;
}

class RestoredIdentityBackup {
  const RestoredIdentityBackup({
    required this.privateKey,
    required this.contacts,
    this.messages = const <MessageModel>[],
    this.conversations = const <ConversationModel>[],
  });

  final String privateKey;
  final List<ContactModel> contacts;
  final List<MessageModel> messages;
  final List<ConversationModel> conversations;
}


String normalizeVaultChatRestorePayload(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), '');
}

class RestoreIdentityDialog extends StatefulWidget {
  const RestoreIdentityDialog({
    required this.identityBackupPrefix,
    required this.dialogWidth,
    required this.isValidPrivateKey,
  });

  final String identityBackupPrefix;
  final double dialogWidth;
  final bool Function(String value) isValidPrivateKey;

  @override
  State<RestoreIdentityDialog> createState() => _RestoreIdentityDialogState();
}

class _RestoreIdentityDialogState extends State<RestoreIdentityDialog> {
  late final TextEditingController _backupController;
  late final TextEditingController _passwordController;
  late final FocusNode _backupFocusNode;
  late final FocusNode _passwordFocusNode;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _backupController = TextEditingController();
    _passwordController = TextEditingController();
    _backupFocusNode = FocusNode();
    _passwordFocusNode = FocusNode();
    _backupController.addListener(_safeRefresh);
    _passwordController.addListener(_safeRefresh);
  }

  void _safeRefresh() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _backupController.removeListener(_safeRefresh);
    _passwordController.removeListener(_safeRefresh);
    _backupFocusNode.dispose();
    _passwordFocusNode.dispose();
    _backupController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cleanPayload = normalizeVaultChatRestorePayload(_backupController.text);
    final password = _passwordController.text;
    final isEncryptedBackup = cleanPayload.startsWith(widget.identityBackupPrefix);
    final isRawKey = widget.isValidPrivateKey(cleanPayload);
    final canRestore = isRawKey || (isEncryptedBackup && password.isNotEmpty);

    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.restore_rounded, color: SecureChatColors.violetSoft),
      title: const Text('Restore identity', textAlign: TextAlign.center),
      content: SizedBox(
        width: widget.dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the encrypted VaultChat backup. A raw 64-character private key is also accepted for legacy compatibility.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _backupController,
              focusNode: _backupFocusNode,
              maxLines: 4,
              minLines: 2,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              // Cap at 32 KB — a real VaultChat backup is well under 8 KB even
              // with hundreds of messages. This prevents memory pressure from
              // an accidental enormous paste.
              inputFormatters: [
                LengthLimitingTextInputFormatter(32768),
              ],
              style: const TextStyle(fontSize: 10.5, height: 1.20, fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: 'Encrypted backup or private key',
                border: const OutlineInputBorder(),
                suffixIcon: canRestore
                    ? const Icon(Icons.check_circle, color: SecureChatColors.turquoise)
                    : const Icon(Icons.error, color: SecureChatColors.danger),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isEncryptedBackup
                  ? 'Encrypted backup detected.'
                  : isRawKey
                      ? 'Raw private key detected.'
                      : '${cleanPayload.length} characters',
              style: TextStyle(
                fontSize: 12,
                color: canRestore || isEncryptedBackup || isRawKey
                    ? SecureChatColors.turquoise
                    : SecureChatColors.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
            Visibility(
              visible: isEncryptedBackup,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  obscureText: _obscurePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Backup password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () {
                        if (!mounted) return;
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: SecureChatColors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: SecureChatColors.warning.withValues(alpha: 0.28)),
              ),
              child: const Text(
                'Restoring replaces the current identity and reconnects the app.',
                style: TextStyle(fontSize: 11, color: SecureChatColors.warning, height: 1.35),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canRestore
              ? () => Navigator.of(context, rootNavigator: true).pop(
                    IdentityRestoreRequest(
                      payload: cleanPayload,
                      password: password,
                    ),
                  )
              : null,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
