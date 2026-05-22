# VaultChat

**Private, encrypted, decentralized messaging built on the Nostr protocol.**

No phone number. No email. No central server.

Your identity is a cryptographic key pair that exists only on your device.

---

## Features

- **NIP-44 v2 encryption** using modern Nostr direct message encryption
- **NIP-04 compatibility fallback** for older encrypted messages
- **Local-first architecture**
- **No phone number registration**
- **No email registration**
- **Biometric authentication**
- **PIN protection**
- **Encrypted local storage**
- **Encrypted backup and restore**
- **Screenshot protection**
- **Screen recording protection**
- **Offline message synchronization**
- **Conversation deletion commands between participating devices**
- **Multi-relay support**
- **Source available for security review**

---

## Security Architecture

```text
Identity:
  secp256k1 key pair

Private Key Storage:
  Android Keystore
  FlutterSecureStorage

Local Database:
  Hive AES-256 encrypted storage

Message Encryption:
  NIP-44 v2
  ECDH secp256k1
  HKDF-SHA256
  ChaCha20-based encryption

Backup Encryption:
  AES-256-GCM
  PBKDF2-HMAC-SHA256
  210,000 iterations

Transport:
  WebSocket Secure (WSS)
  Nostr Relays
```

---

## Technology Stack

| Component | Technology |
|---|---|
| UI | Flutter |
| Language | Dart |
| Messaging Protocol | Nostr |
| Encryption | NIP-44 v2 |
| Legacy Compatibility | NIP-04 fallback |
| Local Storage | Hive |
| Secure Storage | FlutterSecureStorage |
| Cryptography | cryptography |
| secp256k1 / ECDH | pointycastle |
| Authentication | PIN + Biometric |

---

## Build Requirements

- Flutter SDK 3.5+
- Android SDK
- Git

---

## Build

Debug build:

```bash
git clone https://github.com/blejusca/VaultChat.git
cd VaultChat
flutter pub get
flutter build apk --debug
```

APK location:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Release build:

```bash
flutter build apk --release
```

For production releases, configure your own Android keystore.

---

## Relay Configuration

Default public relays:

```text
wss://relay.damus.io
wss://nos.lol
```

For maximum privacy and operational control, a dedicated private relay is recommended.

Public relays can route encrypted messages, but they can still observe metadata such as public keys and timestamps. A private relay reduces dependency on public infrastructure and gives the user or organization more operational control.

---

## Project Structure

```text
lib/
 ├── app/
 ├── auth/
 ├── models/
 ├── screens/
 ├── services/
 ├── theme/
 ├── widgets/
 └── main.dart
```

Core services:

```text
nostr_connection_service.dart
nip44_service.dart
conversation_storage_service.dart
contact_storage_service.dart
secure_key_storage_service.dart
secure_hive_service.dart
pin_lock_service.dart
biometric_lock_service.dart
```

---

## Security Notes

- Private keys are stored locally and are not intended to leave the device unless the user explicitly creates an encrypted backup.
- Message content is end-to-end encrypted.
- Public relays can see metadata such as timestamps and public keys, but not message content.
- Conversation deletion commands are delivered through relays and depend on relay availability and device connectivity.
- For stronger metadata privacy, use a private relay and VPN/Tor.
- Screenshot and screen recording protection are enabled on supported Android devices.
- Android backup is disabled for the app.

---

## Project Status

Current status:

```text
Stable MVP
```

Validated:

- NIP-44 messaging
- NIP-04 fallback for legacy messages
- Backup and restore
- Identity recreation
- Offline message delivery
- PIN authentication
- Biometric authentication
- Screenshot blocking
- Screen recording blocking
- Multi-device testing
- Conversation deletion synchronization
- Message replay prevention after identity deletion
- Restore stability after reinstall
- Reconnect stability after app restart

Tested on:

- Samsung Galaxy Note 10+
- Nokia 5.4

---

## Roadmap

Planned next steps:

1. Private relay deployment
2. Relay configuration interface
3. Additional reliability testing
4. UI and onboarding polish
5. Release signing workflow
6. Play Store preparation

---

## License

Copyright © 2026 VaultChat Project

All Rights Reserved.

This repository is published for transparency, documentation, security review, and development purposes.

No part of this software may be copied, modified, redistributed, relicensed, incorporated into commercial products, or used for commercial purposes without explicit written permission from the copyright holder.

---

## Project

VaultChat is an independent privacy-focused messaging project built on the Nostr ecosystem.
