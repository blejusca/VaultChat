import 'package:flutter/material.dart';

import '../auth/pin_gate.dart';
import '../theme/secure_chat_theme.dart';

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
