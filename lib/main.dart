import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/vault_chat_app.dart';

void main() {
  // Catch Flutter framework errors and prevent them from crashing the app
  // in release mode. In debug mode errors are still thrown normally.
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
    // In release mode: swallow the error silently — no crash dialog exposed.
  };

  // Catch async errors not caught by Flutter framework
  runZonedGuarded(
    () => runApp(const VaultChatApp()),
    (error, stack) {
      if (kDebugMode) {
        // ignore: avoid_print
        debugPrint('Uncaught async error: $error\n$stack');
      }
    },
  );
}
