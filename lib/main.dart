import 'dart:async';

import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/conversation_model.dart';
import 'models/contact_model.dart';
import 'models/message_model.dart';
import 'screens/chat_screen.dart';
import 'screens/inbox_screen.dart';
import 'services/conversation_storage_service.dart';
import 'services/contact_storage_service.dart';
import 'services/nostr_connection_service.dart';
import 'services/pin_lock_service.dart';
import 'services/biometric_lock_service.dart';
import 'theme/secure_chat_theme.dart';

void main() {
  runApp(const VaultChatApp());
}

class VaultChatApp extends StatelessWidget {
  const VaultChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VaultChat',
      debugShowCheckedModeBanner: false,
      theme: SecureChatTheme.dark(),
      home: const PinGate(),
    );
  }
}


class PinGate extends StatefulWidget {
  const PinGate({super.key});

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  final PinLockService _pinService = PinLockService();
  final BiometricLockService _biometricService = BiometricLockService();

  bool _isLoading = true;
  bool _hasPin = false;
  bool _isConfirmingNewPin = false;
  bool _isBusy = false;
  bool _wasWiped = false;
  bool _isBiometricAvailable = false;
  bool _isBiometricAuthenticating = false;
  bool _didAutoPromptBiometric = false;

  String _biometricLabel = 'Deblocare biometrica';

  String _newPin = '';
  String _confirmPin = '';
  String _enteredPin = '';
  String _errorMessage = '';
  int _failedAttempts = 0;

  @override
  void initState() {
    super.initState();
    _loadPinState();
  }

  Future<void> _loadPinState() async {
    try {
      final hasPin = await _pinService.hasPin();
      final attempts = await _pinService.failedAttempts();
      final biometricSupport = hasPin
          ? await _biometricService.supportState()
          : const BiometricSupportState(
              isAvailable: false,
              label: 'Deblocare biometrica',
            );

      if (!mounted) return;
      if (mounted) setState(() {
        _hasPin = hasPin;
        _failedAttempts = attempts;
        _isBiometricAvailable = biometricSupport.isAvailable;
        _biometricLabel = biometricSupport.label;
        _isLoading = false;
      });

      if (hasPin && biometricSupport.isAvailable) {
        Future.delayed(const Duration(milliseconds: 350), () {
          if (!mounted || _didAutoPromptBiometric) return;
          _didAutoPromptBiometric = true;
          unawaited(_tryBiometricUnlock(autoPrompt: true));
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (mounted) setState(() {
        _errorMessage = 'Eroare PIN: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _tryBiometricUnlock({bool autoPrompt = false}) async {
    if (!_hasPin || !_isBiometricAvailable || _isBusy || _isBiometricAuthenticating) {
      return;
    }

    if (mounted) {
      setState(() {
        _isBiometricAuthenticating = true;
        if (!autoPrompt) _errorMessage = '';
      });
    }

    final success = await _biometricService.authenticate();

    if (!mounted) return;

    if (success) {
      _openVaultChatRoot();
      return;
    }

    setState(() {
      _isBiometricAuthenticating = false;
      if (!autoPrompt) {
        _errorMessage = 'Deblocarea biometrica a fost anulata. Foloseste PIN-ul.';
      }
    });
  }

  void _handleDigit(String digit) {
    if (_isBusy) return;

    if (_hasPin) {
      _addVerifyDigit(digit);
    } else {
      _addCreateDigit(digit);
    }
  }

  void _handleDelete() {
    if (_isBusy) return;

    if (_hasPin) {
      if (_enteredPin.isEmpty) return;
      if (mounted) setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
        _errorMessage = '';
      });
      return;
    }

    if (_isConfirmingNewPin) {
      if (_confirmPin.isEmpty) return;
      if (mounted) setState(() {
        _confirmPin = _confirmPin.substring(0, _confirmPin.length - 1);
        _errorMessage = '';
      });
    } else {
      if (_newPin.isEmpty) return;
      if (mounted) setState(() {
        _newPin = _newPin.substring(0, _newPin.length - 1);
        _errorMessage = '';
      });
    }
  }

  void _addCreateDigit(String digit) {
    if (!_isConfirmingNewPin) {
      if (_newPin.length >= PinLockService.pinLength) return;
      if (mounted) setState(() {
        _newPin += digit;
        _errorMessage = '';
      });

      if (_newPin.length == PinLockService.pinLength) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          setState(() => _isConfirmingNewPin = true);
        });
      }
      return;
    }

    if (_confirmPin.length >= PinLockService.pinLength) return;
    if (mounted) setState(() {
      _confirmPin += digit;
      _errorMessage = '';
    });

    if (_confirmPin.length == PinLockService.pinLength) {
      Future.delayed(const Duration(milliseconds: 150), _createPinIfValid);
    }
  }

  void _addVerifyDigit(String digit) {
    if (_enteredPin.length >= PinLockService.pinLength) return;

    if (mounted) setState(() {
      _enteredPin += digit;
      _errorMessage = '';
    });

    if (_enteredPin.length == PinLockService.pinLength) {
      Future.delayed(const Duration(milliseconds: 150), _verifyPin);
    }
  }

  Future<void> _createPinIfValid() async {
    if (!mounted || _isBusy) return;

    if (_newPin != _confirmPin) {
      if (mounted) setState(() {
        _newPin = '';
        _confirmPin = '';
        _isConfirmingNewPin = false;
        _errorMessage = 'PIN-urile nu coincid. Incearca din nou.';
      });
      return;
    }

    setState(() => _isBusy = true);

    try {
      await _pinService.createPin(_newPin);
      if (!mounted) return;
      _openVaultChatRoot();
    } catch (e) {
      if (!mounted) return;
      if (mounted) setState(() {
        _errorMessage = 'Nu am putut salva PIN-ul: $e';
        _newPin = '';
        _confirmPin = '';
        _isConfirmingNewPin = false;
        _isBusy = false;
      });
    }
  }

  Future<void> _verifyPin() async {
    if (!mounted || _isBusy) return;

    setState(() => _isBusy = true);

    try {
      final result = await _pinService.verifyPin(_enteredPin);

      if (!mounted) return;

      if (result.success) {
        _openVaultChatRoot();
        return;
      }

      if (result.wiped) {
        await _showWipeDialog();
        if (!mounted) return;
        if (mounted) setState(() {
          _hasPin = false;
          _isBusy = false;
          _failedAttempts = 0;
          _enteredPin = '';
          _newPin = '';
          _confirmPin = '';
          _isConfirmingNewPin = false;
          _wasWiped = true;
          _errorMessage = '';
        });
        return;
      }

      if (mounted) setState(() {
        _failedAttempts = PinLockService.maxAttempts - result.attemptsLeft;
        _enteredPin = '';
        _isBusy = false;
        _errorMessage = 'PIN incorect. ${result.attemptsLeft} incercari ramase.';
      });
    } catch (e) {
      if (!mounted) return;
      if (mounted) setState(() {
        _enteredPin = '';
        _isBusy = false;
        _errorMessage = 'Eroare verificare PIN: $e';
      });
    }
  }

  Future<void> _showWipeDialog() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Date sterse'),
        icon: const Icon(Icons.delete_forever, color: SecureChatColors.danger, size: 34),
        content: const Text(
          'Ai depasit numarul maxim de incercari.\n\n'
          'Cheia privata, PIN-ul si mesajele salvate local au fost sterse.\n\n'
          'Pentru a recupera identitatea veche, creeaza un PIN nou, apoi foloseste Restaureaza identitatea din meniul cu cheia.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }


  Future<void> _confirmForgotPinWipe() async {
    if (!mounted || _isBusy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.warning_amber_rounded, color: SecureChatColors.danger, size: 36),
        title: const Text('Resetezi VaultChat?'),
        content: const Text(
          'Daca ai uitat PIN-ul, singura metoda sigura este stergerea completa a datelor locale.\n\n'
          'Se vor sterge de pe acest telefon:\n'
          '• PIN-ul actual;\n'
          '• cheia privata locala;\n'
          '• mesajele si conversatiile locale;\n'
          '• contactele locale.\n\n'
          'Aceasta actiune este ireversibila. Poti recupera identitatea doar daca ai exportat cheia privata anterior.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Anuleaza'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: SecureChatColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_forever_rounded),
            label: const Text('Sterge si reseteaza'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isBusy = true;
      _errorMessage = '';
    });

    try {
      await _pinService.wipeAllApplicationData();

      if (!mounted) return;
      setState(() {
        _hasPin = false;
        _isBusy = false;
        _failedAttempts = 0;
        _enteredPin = '';
        _newPin = '';
        _confirmPin = '';
        _isConfirmingNewPin = false;
        _wasWiped = true;
        _isBiometricAvailable = false;
        _isBiometricAuthenticating = false;
        _didAutoPromptBiometric = false;
        _errorMessage = '';
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.lock_reset_rounded, color: SecureChatColors.violetSoft, size: 34),
          title: const Text('Vault resetat'),
          content: const Text(
            'Datele locale au fost sterse. Creeaza un PIN nou pentru a folosi aplicatia.\n\n'
            'Daca vrei sa revii la identitatea veche, restaureaza cheia privata din backup dupa ce intri in aplicatie.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = 'Nu am putut reseta VaultChat: $e';
      });
    }
  }

  void _openVaultChatRoot() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const VaultChatRoot()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final currentPin = _hasPin
        ? _enteredPin
        : _isConfirmingNewPin
            ? _confirmPin
            : _newPin;

    final title = _hasPin
        ? 'VaultChat'
        : _isConfirmingNewPin
            ? 'Confirma PIN-ul'
            : 'Creaza PIN';

    final subtitle = _hasPin
        ? 'Introdu PIN-ul pentru a accesa aplicatia.'
        : _isConfirmingNewPin
            ? 'Introdu din nou PIN-ul pentru confirmare.'
            : _wasWiped
                ? 'Datele locale au fost sterse. Creeaza un PIN nou, apoi restaureaza cheia privata daca ai backup.'
                : 'Alege un PIN de 6 cifre pentru protectia locala.';

    final attemptsLeft = PinLockService.maxAttempts - _failedAttempts;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [SecureChatColors.voidBlack, SecureChatColors.deepNavy, Color(0xFF11162A)],
          ),
        ),
        child: SafeArea(
          child: _PinEntryScreen(
            title: title,
            subtitle: subtitle,
            currentPinLength: currentPin.length,
            errorMessage: _errorMessage,
            isBusy: _isBusy,
            showAttemptsWarning: _hasPin && _failedAttempts >= 5 && _errorMessage.isEmpty,
            attemptsLeft: attemptsLeft,
            biometricLabel: _biometricLabel,
            showBiometricButton: _hasPin && _isBiometricAvailable,
            isBiometricAuthenticating: _isBiometricAuthenticating,
            onBiometricUnlock: () => _tryBiometricUnlock(),
            showForgotPinButton: _hasPin,
            onForgotPin: _confirmForgotPinWipe,
            onDigit: _handleDigit,
            onDelete: _handleDelete,
          ),
        ),
      ),
    );
  }
}

class _PinEntryScreen extends StatelessWidget {
  final String title;
  final String subtitle;
  final int currentPinLength;
  final String errorMessage;
  final bool isBusy;
  final bool showAttemptsWarning;
  final int attemptsLeft;
  final String biometricLabel;
  final bool showBiometricButton;
  final bool isBiometricAuthenticating;
  final VoidCallback onBiometricUnlock;
  final bool showForgotPinButton;
  final VoidCallback onForgotPin;
  final void Function(String digit) onDigit;
  final VoidCallback onDelete;

  const _PinEntryScreen({
    required this.title,
    required this.subtitle,
    required this.currentPinLength,
    required this.errorMessage,
    required this.isBusy,
    required this.showAttemptsWarning,
    required this.attemptsLeft,
    required this.biometricLabel,
    required this.showBiometricButton,
    required this.isBiometricAuthenticating,
    required this.onBiometricUnlock,
    required this.showForgotPinButton,
    required this.onForgotPin,
    required this.onDigit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SizedBox(height: 24),
                  Column(
                    children: [
                      Container(
                        width: 78,
                        height: 78,
                        decoration: BoxDecoration(
                          color: SecureChatColors.violet.withOpacity(0.16),
                          shape: BoxShape.circle,
                          boxShadow: SecureChatShadows.subtleGlow,
                        ),
                        child: const Icon(
                          Icons.lock_outline_rounded,
                          size: 42,
                          color: SecureChatColors.violetBright,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.45,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: SecureChatColors.mutedText,
                          fontSize: 14,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      _PinDots(filledCount: currentPinLength),
                      const SizedBox(height: 14),
                      if (isBusy)
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (errorMessage.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            errorMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: SecureChatColors.danger, fontSize: 13),
                          ),
                        )
                      else if (showAttemptsWarning)
                        Text(
                          'Atentie: $attemptsLeft incercari ramase.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: SecureChatColors.warning,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else
                        const SizedBox(height: 22),
                    ],
                  ),
                  if (showBiometricButton) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: isBusy || isBiometricAuthenticating
                          ? null
                          : onBiometricUnlock,
                      icon: isBiometricAuthenticating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fingerprint_rounded),
                      label: Text(
                        isBiometricAuthenticating
                            ? 'Se verifica...'
                            : biometricLabel,
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 13,
                        ),
                        side: BorderSide(
                          color: SecureChatColors.violetBright.withOpacity(0.55),
                        ),
                      ),
                    ),
                  ],
                  if (showForgotPinButton) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: isBusy ? null : onForgotPin,
                      icon: const Icon(Icons.lock_reset_rounded, size: 18),
                      label: const Text('Am uitat PIN-ul'),
                      style: TextButton.styleFrom(
                        foregroundColor: SecureChatColors.mutedText,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _PinKeyboard(onDigit: onDigit, onDelete: onDelete),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PinDots extends StatelessWidget {
  final int filledCount;

  const _PinDots({required this.filledCount});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(PinLockService.pinLength, (index) {
        final isFilled = index < filledCount;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled
                ? SecureChatColors.violetBright
                : SecureChatColors.cardAlt,
            border: Border.all(
              color: isFilled
                  ? SecureChatColors.violetBright
                  : SecureChatColors.border,
            ),
          ),
        );
      }),
    );
  }
}

class _PinKeyboard extends StatelessWidget {
  final void Function(String digit) onDigit;
  final VoidCallback onDelete;

  const _PinKeyboard({
    required this.onDigit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _row(['1', '2', '3']),
        const SizedBox(height: 10),
        _row(['4', '5', '6']),
        const SizedBox(height: 10),
        _row(['7', '8', '9']),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            const SizedBox(width: 64, height: 64),
            _digitButton('0'),
            _deleteButton(),
          ],
        ),
      ],
    );
  }

  Widget _row(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map(_digitButton).toList(),
    );
  }

  Widget _digitButton(String digit) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Material(
        color: SecureChatColors.cardAlt.withOpacity(0.82),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => onDigit(digit),
          child: Center(
            child: Text(
              digit,
              style: const TextStyle(
                color: SecureChatColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _deleteButton() {
    return SizedBox(
      width: 64,
      height: 64,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onDelete,
          child: const Center(
            child: Icon(Icons.backspace_outlined, size: 26, color: SecureChatColors.mutedText),
          ),
        ),
      ),
    );
  }
}


class _ContactDialogResult {
  final String displayName;
  final String publicKeyOrPayload;

  const _ContactDialogResult({
    required this.displayName,
    required this.publicKeyOrPayload,
  });
}

class _ContactEntrySheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final String actionLabel;
  final bool requireName;

  const _ContactEntrySheet({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.requireName,
  });

  @override
  State<_ContactEntrySheet> createState() => _ContactEntrySheetState();
}

class _ContactEntrySheetState extends State<_ContactEntrySheet> {
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
    Navigator.of(context).pop(
      _ContactDialogResult(
        displayName: _nameController.text.trim(),
        publicKeyOrPayload: _keyController.text.trim(),
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
                        color: SecureChatColors.borderSoft.withOpacity(0.8),
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
                          color: SecureChatColors.violet.withOpacity(0.16),
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

  static const String _privateKeyStorageKey = 'nostr_private_key_hex';
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
  DateTime? _backgroundedAt;
  bool _isNavigatingToLock = false;

  SecureChatConnectionSnapshot _connectionSnapshot =
      SecureChatConnectionSnapshot(
    state: SecureChatConnectionState.idle,
    label: 'Se initializeaza...',
    updatedAt: DateTime.now(),
  );

  String get _publicKey => _keyPair?.public ?? '';
  String get _privateKey => _keyPair?.private ?? '';

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
    final prefs = await SharedPreferences.getInstance();
    final savedPrivateKey = prefs.getString(_privateKeyStorageKey);

    if (savedPrivateKey != null && savedPrivateKey.trim().isNotEmpty) {
      _keyPair = _nostr.keys.generateKeyPairFromExistingPrivateKey(
        savedPrivateKey.trim(),
      );
    } else {
      final newPair = _nostr.keys.generateKeyPair();
      await prefs.setString(_privateKeyStorageKey, newPair.private);
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
    final result = await showModalBottomSheet<_ContactDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => const _ContactEntrySheet(
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
    final result = await showModalBottomSheet<_ContactDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => const _ContactEntrySheet(
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


  // ─── EXPORT cheie privata ───────────────────────────────────────────────────

  void _showExportKeyDialog() {
    // Pasul 1: avertizare
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.warning_amber_rounded, color: SecureChatColors.danger),
        title: const Text('Atentie!', textAlign: TextAlign.center, style: TextStyle(color: SecureChatColors.danger)),
        content: const Text(
          'Cheia privata este SECRETUL TAU ABSOLUT.\n\n'
          'Nu o arata nimanui, niciodata.\n\n'
          'Oricine o are poate citi toate conversatiile tale si se poate da drept tine.\n\n'
          'Salveaz-o OFFLINE, intr-un loc sigur fizic.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anuleaza'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SecureChatColors.danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Inteleg, arata cheia'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed != true) return;
      if (!mounted) return;
      // Pasul 2: afisare cheie
      _showPrivateKeyRevealDialog();
    });
  }

  void _showPrivateKeyRevealDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.lock_open_rounded, color: SecureChatColors.danger),
        title: const Text('Cheia ta privata', textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Copiaz-o si salveaz-o offline in siguranta:',
              style: TextStyle(fontSize: 12, color: SecureChatColors.mutedText),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: SecureChatColors.danger.withOpacity(0.10),
                border: Border.all(color: SecureChatColors.danger.withOpacity(0.36)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _privateKey,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: SecureChatColors.text,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: SecureChatColors.danger,
                ),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: _privateKey),
                  );
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  if (!mounted) return;
                  _showSnackBar(
                    'Cheie privata copiata! Salveaz-o offline imediat.',
                    isError: true,
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copiaza cheia privata'),
              ),
            ),
          ],
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

  // ─── IMPORT (Restore) cheie privata ────────────────────────────────────────

  Future<void> _showRestoreKeyDialog() async {
    final controller = TextEditingController();

    try {
      final privateKey = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final text = controller.text.trim();
              final isValid = _isValidPrivateKey(text);
              final length = text.length;

              return AlertDialog(
        scrollable: true,
                icon: const Icon(Icons.restore, size: 32),
                title: const Text(
                  'Restaureaza contul',
                  textAlign: TextAlign.center,
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Introdu cheia privata hex salvata anterior.',
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: controller,
                        maxLines: 2,
                        minLines: 1,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          isDense: true,
                          labelText: 'Cheie privata hex',
                          suffixIcon: isValid
                              ? const Icon(Icons.check_circle,
                                  color: SecureChatColors.turquoise)
                              : const Icon(Icons.error, color: SecureChatColors.danger),
                        ),
                        onChanged: (value) {
                          final cleaned = value.replaceAll(
                            RegExp(r'[^a-fA-F0-9]'),
                            '',
                          );
                          if (cleaned != value) {
                            controller.value = TextEditingValue(
                              text: cleaned,
                              selection: TextSelection.collapsed(
                                offset: cleaned.length,
                              ),
                            );
                          }
                          setDialogState(() {});
                        },
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$length/64 caractere',
                        style: TextStyle(
                          fontSize: 12,
                          color: isValid ? SecureChatColors.turquoise : SecureChatColors.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isValid) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: SecureChatColors.warning.withOpacity(0.10),
                            border: Border.all(color: SecureChatColors.warning.withOpacity(0.32)),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Restaurarea va inlocui identitatea curenta si va reconecta aplicatia automat.',
                            style: TextStyle(
                              fontSize: 11,
                              color: SecureChatColors.warning,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Anuleaza'),
                  ),
                  FilledButton(
                    onPressed: isValid
                        ? () => Navigator.pop(dialogContext, text)
                        : null,
                    child: const Text('Restaureaza'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (privateKey != null && _isValidPrivateKey(privateKey)) {
        await _restorePrivateKey(privateKey.trim());
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _restorePrivateKey(String privateKey) async {
    try {
      final restoredPair = _nostr.keys
          .generateKeyPairFromExistingPrivateKey(privateKey.trim());

      if (restoredPair.public.isEmpty) {
        _showSnackBar('Cheie invalida — nu s-a putut restaura.', isError: true);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_privateKeyStorageKey, privateKey.trim());

      _keyPair = restoredPair;
      await _restartConnectionForCurrentIdentity();
      await _reloadConversations();

      if (!mounted) return;
      _showSnackBar('Identitate restaurata si reconectata cu succes.');
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Cheie invalida: $e', isError: true);
    }
  }

  // ─── DIALOG IDENTITATE (cu toate optiunile) ────────────────────────────────

  void _showKeysDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.key_rounded, color: SecureChatColors.violetSoft),
        title: const Text('Identitatea ta', textAlign: TextAlign.center),
        content: Column(
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
                color: SecureChatColors.cardAlt.withOpacity(0.72),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _publicKey,
                style:
                    const TextStyle(fontSize: 11, fontFamily: 'monospace'),
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
                  side: BorderSide(color: SecureChatColors.danger.withOpacity(0.55)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _showExportKeyDialog();
                },
                icon: const Icon(Icons.download),
                label: const Text('Exporta cheia privata'),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? SecureChatColors.danger : null,
        duration: const Duration(seconds: 4),
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