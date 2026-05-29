# VaultChat

**Private. Encrypted. Decentralized.**

VaultChat is a peer-to-peer encrypted messenger built on the Nostr protocol.
No phone number. No email. No registration. No central server.

[![GitHub release](https://img.shields.io/github/v/release/blejusca/VaultChat)](https://github.com/blejusca/VaultChat/releases/latest)
[![License](https://img.shields.io/badge/license-All%20Rights%20Reserved-red)](LICENSE)

🌐 **Official website:** [https://vaultchat.pro](https://vaultchat.pro)

---

## Demo

[![VaultChat Demo](https://img.youtube.com/vi/HraWOmTGj_s/maxresdefault.jpg)](https://youtu.be/HraWOmTGj_s)

---

## Download

| Platform | Link |
|----------|------|
| Android APK (direct) | [Download v0.9.9](https://github.com/blejusca/VaultChat/releases/latest) |
| Google Play | Coming soon |

---

## Features

- 🔐 End-to-end encrypted messaging (NIP-44 v2)
- 📡 Decentralized via Nostr relays — no central server
- 📷 QR contact sharing and scanning
- 🔒 PIN & biometric authentication
- 📎 Encrypted file transfer (images, PDFs, documents)
- 💾 Encrypted identity backup and restore
- 🗑️ Synchronized conversation delete (both sides)
- 🔍 Contact search
- 🌐 Multi-relay support
- 👤 No account required — identity generated locally

---

## Why VaultChat?

Most messaging platforms require your phone number, email, or personal data.
VaultChat works differently.

Your identity is a cryptographic key pair generated **locally on your device**.
Nobody can access your messages — not even the developers.

| | Signal | WhatsApp | Telegram | **VaultChat** |
|---|---|---|---|---|
| Phone number required | ✅ | ✅ | ✅ | ❌ |
| Central server | ✅ | ✅ | ✅ | ❌ |
| Account registration | ✅ | ✅ | ✅ | ❌ |
| Open protocol | ❌ | ❌ | ❌ | ✅ Nostr |
| Self-sovereign identity | ❌ | ❌ | ❌ | ✅ |

---

## Security

- End-to-end encryption (NIP-44 v2 — ChaCha20 + HMAC-SHA256)
- Local identity storage (never leaves your device unencrypted)
- AES-256-GCM encrypted local database (Hive)
- Screenshot blocking
- PIN + biometric lock
- No central database
- No personal data collection
- Open source for transparency

---

## Technology

- **Flutter** / Dart
- **Nostr Protocol** (NIP-04, NIP-44)
- **Hive** encrypted local storage
- **AES-256-GCM** for file encryption

---

## Project Status

**Current stable release: v0.9.9**

The project is actively developed. Recent fixes in v0.9.9:
- Deleted conversations no longer reappear after relay reconnect
- Persistent event deduplication across app restarts
- Tombstone system with timestamp cutoff

---

## Feedback & Support

- 🌐 Website: [https://vaultchat.pro](https://vaultchat.pro)
- 🐛 Bug reports: [GitHub Issues](https://github.com/blejusca/VaultChat/issues)
- 💬 Discussions: [GitHub Discussions](https://github.com/blejusca/VaultChat/discussions)
- 🚀 Product Hunt: [VaultChat on Product Hunt](https://www.producthunt.com/products/vaultchat-private-nostr-messenger)
