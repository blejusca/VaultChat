# Nostr Basic App - ghid pentru incepatori

Acest ZIP contine un proiect Flutter simplu pentru Android. Aplicatia are un camp de text, un buton `Trimite`, se conecteaza la relay-ul Nostr `wss://relay.damus.io` prin WebSocket si afiseaza mesajele local in lista.

Important: aplicatia NU publica inca mesaje Nostr reale, pentru ca un event Nostr real trebuie semnat criptografic cu o cheie privata. Aceasta versiune este doar baza: interfata + conexiune WebSocket.

## Cum pornesti proiectul

1. Instaleaza Git, Flutter si Android Studio conform ghidului din raspunsul ChatGPT.
2. Dezarhiveaza acest ZIP intr-un folder simplu, de exemplu: `C:\Proiecte\nostr_basic_app`.
3. Deschide PowerShell.
4. Scrie:

```powershell
cd C:\Proiecte\nostr_basic_app
flutter pub get
flutter run
```

## Fisiere importante

- `pubspec.yaml` - lista de setari si dependinte Flutter.
- `lib/main.dart` - codul principal al aplicatiei.
- `android/` - fisierele necesare pentru rularea pe Android.

Daca Flutter cere regenerarea fisierelor Android, ruleaza in folderul proiectului:

```powershell
flutter create --platforms=android .
```

Apoi ruleaza din nou:

```powershell
flutter pub get
flutter run
```
