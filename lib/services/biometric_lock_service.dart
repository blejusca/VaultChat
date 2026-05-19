import 'package:local_auth/local_auth.dart';

class BiometricLockService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<BiometricSupportState> supportState() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      final biometrics = await _auth.getAvailableBiometrics();

      if (!supported || (!canCheck && biometrics.isEmpty)) {
        return const BiometricSupportState(
          isAvailable: false,
          label: 'Biometria nu este disponibila pe acest dispozitiv.',
        );
      }

      final label = _labelFor(biometrics);
      return BiometricSupportState(isAvailable: true, label: label);
    } catch (_) {
      return const BiometricSupportState(
        isAvailable: false,
        label: 'Biometria nu poate fi verificata momentan.',
      );
    }
  }

  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Deblocheaza VaultChat pentru a accesa mesajele criptate.',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  String _labelFor(List<BiometricType> biometrics) {
    if (biometrics.contains(BiometricType.face)) {
      return 'Deblocare cu Face Unlock';
    }
    if (biometrics.contains(BiometricType.fingerprint)) {
      return 'Deblocare cu amprenta';
    }
    if (biometrics.contains(BiometricType.strong) ||
        biometrics.contains(BiometricType.weak)) {
      return 'Deblocare biometrica';
    }
    return 'Deblocare securizata';
  }
}

class BiometricSupportState {
  final bool isAvailable;
  final String label;

  const BiometricSupportState({
    required this.isAvailable,
    required this.label,
  });
}
