import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/secure_chat_theme.dart';

class ContactDialogResult {
  final String displayName;
  final String publicKeyOrPayload;

  const ContactDialogResult({
    required this.displayName,
    required this.publicKeyOrPayload,
  });
}

class ContactEntrySheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final String actionLabel;
  final bool requireName;

  const ContactEntrySheet({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.requireName,
  });

  @override
  State<ContactEntrySheet> createState() => _ContactEntrySheetState();
}

class _ContactEntrySheetState extends State<ContactEntrySheet> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _keyFocusNode = FocusNode();

  @override
  void dispose() {
    _nameController.dispose();
    _keyController.dispose();
    _nameFocusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  String? _extractPublicKey(String value) {
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

  bool get _hasValidKey => _extractPublicKey(_keyController.text) != null;
  bool get _hasValidName => !widget.requireName || _nameController.text.trim().isNotEmpty;
  bool get _canSubmit => _hasValidKey && _hasValidName;

  void _submit() {
    if (!_canSubmit) return;
    // Always submit the extracted 64-char hex key, never the raw pasted text.
    // This ensures callers always receive a clean, canonical public key
    // regardless of what the user pasted (URL, text with spaces, full payload).
    final cleanKey = _extractPublicKey(_keyController.text);
    if (cleanKey == null) return;
    Navigator.of(context).pop(
      ContactDialogResult(
        displayName: _nameController.text.trim(),
        publicKeyOrPayload: cleanKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final key = _extractPublicKey(_keyController.text);
    final keyLength = key?.length ?? _keyController.text.trim().length;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.64,
        minChildSize: 0.38,
        maxChildSize: 0.90,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              gradient: SecureChatGradients.card,
              borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
              border: Border(
                top: BorderSide(color: SecureChatColors.borderSoft),
              ),
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: SecureChatColors.borderSoft.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: SecureChatColors.violet.withValues(alpha: 0.16),
                        ),
                        child: const Icon(
                          Icons.person_add_alt_1_rounded,
                          color: SecureChatColors.violetSoft,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            color: SecureChatColors.text,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.subtitle,
                    style: const TextStyle(
                      color: SecureChatColors.mutedText,
                      height: 1.35,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _nameController,
                    focusNode: _nameFocusNode,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _keyFocusNode.requestFocus(),
                    decoration: InputDecoration(
                      labelText: widget.requireName
                          ? 'Nume contact'
                          : 'Nume contact optional',
                      prefixIcon: const Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _keyController,
                    focusNode: _keyFocusNode,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.done,
                    // Sanitize on every change/paste: strip whitespace and
                    // cap at 512 chars so huge accidental pastes cannot flood
                    // the field. The key extractor handles embedded 64-char
                    // hex sequences, so no valid input is ever rejected.
                    inputFormatters: [
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        final cleaned = newValue.text.replaceAll(RegExp(r'\s'), ' ').trimLeft();
                        if (cleaned.length > 512) {
                          final capped = cleaned.substring(0, 512);
                          return newValue.copyWith(
                            text: capped,
                            selection: TextSelection.collapsed(offset: capped.length),
                          );
                        }
                        return newValue.copyWith(text: cleaned);
                      }),
                    ],
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'ID public sau link VaultChat',
                      prefixIcon: const Icon(Icons.key_rounded),
                      suffixIcon: _hasValidKey
                          ? const Icon(Icons.check_circle, color: SecureChatColors.turquoise)
                          : const Icon(Icons.error, color: SecureChatColors.danger),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _hasValidKey ? 'ID valid detectat.' : '$keyLength/64 caractere',
                    style: TextStyle(
                      color: _hasValidKey ? SecureChatColors.turquoise : SecureChatColors.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Anuleaza'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _canSubmit ? _submit : null,
                          child: Text(widget.actionLabel),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

