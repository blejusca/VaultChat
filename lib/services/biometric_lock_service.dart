import 'package:local_auth/local_auth.dart';

class BiometricLockService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<BiometricSupportState> supportState() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      final biometrics = await _auth.getAvailableBiometrics();

      // SECURITY: VaultChat must never use Android device credential fallback
      // (device PIN / pattern / password) as biometric unlock. Some Android builds
      // can report `canCheckBiometrics == true` even when no biometric template is
      // enrolled. In that case the app must hide the biometric button and require
      // the local VaultChat PIN.
      if (!supported || !canCheck || biometrics.isEmpty) {
        return const BiometricSupportState(
          isAvailable: false,
          label: 'Biometria nu este configurata pe acest dispozitiv.',
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
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      final biometrics = await _auth.getAvailableBiometrics();

      // SECURITY: do not start Android auth UI unless a real biometric method is
      // enrolled. This prevents device PIN / password fallback and avoids stale
      // platform-auth sessions being interpreted as a VaultChat unlock.
      if (!supported || !canCheck || biometrics.isEmpty) {
        return false;
      }

      return await _auth.authenticate(
        localizedReason: 'Deblocheaza VaultChat pentru a accesa mesajele criptate.',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
          useErrorDialogs: false,
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
