import 'dart:async';

import 'package:flutter/material.dart';

import '../app/vault_chat_root.dart';
import '../services/biometric_lock_service.dart';
import '../services/pin_lock_service.dart';
import '../theme/secure_chat_theme.dart';

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

  String _biometricLabel = 'Biometric unlock';

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
              label: 'Biometric unlock',
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
        _errorMessage = 'PIN error: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _tryBiometricUnlock({bool autoPrompt = false}) async {
    if (!_hasPin || _isBusy || _isBiometricAuthenticating) {
      return;
    }

    // Defensive re-check immediately before launching the platform biometric UI.
    // The cached value from startup is not enough on Android: the user may remove
    // biometrics, or the device may report generic credential support without an
    // enrolled fingerprint/face. In those cases VaultChat must require the local PIN.
    final biometricSupport = await _biometricService.supportState();
    if (!mounted) return;

    if (!biometricSupport.isAvailable) {
      setState(() {
        _isBiometricAvailable = false;
        _isBiometricAuthenticating = false;
        if (!autoPrompt) {
          _errorMessage = 'Biometrics not set up. Use your VaultChat PIN.';
        }
      });
      return;
    }

    setState(() {
      _isBiometricAvailable = true;
      _biometricLabel = biometricSupport.label;
      _isBiometricAuthenticating = true;
      if (!autoPrompt) _errorMessage = '';
    });

    final success = await _biometricService.authenticate();

    if (!mounted) return;

    if (success && _hasPin) {
      setState(() => _isBiometricAuthenticating = false);
      _openVaultChatRoot();
      return;
    }

    setState(() {
      _isBiometricAuthenticating = false;
      if (!autoPrompt) {
        _errorMessage = 'Biometric unlock cancelled. Use your PIN.';
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
        _errorMessage = 'PINs do not match. Please try again.';
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
        _errorMessage = 'Could not save PIN: $e';
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
        _errorMessage = 'Incorrect PIN. ${result.attemptsLeft} attempts remaining.';
      });
    } catch (e) {
      if (!mounted) return;
      if (mounted) setState(() {
        _enteredPin = '';
        _isBusy = false;
        _errorMessage = 'PIN verification error: $e';
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
        title: const Text('Data deleted'),
        icon: const Icon(Icons.delete_forever, color: SecureChatColors.danger, size: 34),
        content: const Text(
          'You have exceeded the maximum number of attempts.\n\n'
          'The private key, PIN, and locally saved messages were deleted.\n\n'
          'To recover the old identity, create a new PIN, then use Restore identity from the key menu.',
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
        title: const Text('Reset VaultChat?'),
        content: const Text(
          'If you forgot the PIN, the only safe method is to completely delete local data.\n\n'
          'This will be deleted from this phone:\n'
          '• current PIN;\n'
          '• local private key;\n'
          '• local messages and conversations;\n'
          '• local contacts.\n\n'
          'This action is irreversible. You can recover the identity only if you previously exported the private key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: SecureChatColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_forever_rounded),
            label: const Text('Delete and reset'),
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
          title: const Text('VaultChat reset'),
          content: const Text(
            'Local data was deleted. Create a new PIN to use the app.\n\n'
            'If you want to return to the old identity, restore the private key from backup after entering the app.',
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
        _errorMessage = 'Could not reset VaultChat: $e';
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
            ? 'Confirm your PIN'
            : 'Create PIN';

    final subtitle = _hasPin
        ? 'Enter your PIN to access the app.'
        : _isConfirmingNewPin
            ? 'Enter your PIN again to confirm.'
            : _wasWiped
                ? 'Local data was deleted. Create a new PIN, then restore the private key if you have a backup.'
                : 'Choose a 6-digit PIN for local protection.';

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
                          color: SecureChatColors.violet.withValues(alpha: 0.16),
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
                          'Warning: $attemptsLeft attempts remaining.',
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
                          color: SecureChatColors.violetBright.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ],
                  if (showForgotPinButton) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: isBusy ? null : onForgotPin,
                      icon: const Icon(Icons.lock_reset_rounded, size: 18),
                      label: const Text('Forgot PIN'),
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
        color: SecureChatColors.cardAlt.withValues(alpha: 0.82),
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


