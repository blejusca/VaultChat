import 'dart:async';
import 'dart:convert';

import 'package:dart_nostr/dart_nostr.dart';
import 'package:nip04/nip04.dart';

import '../models/message_model.dart';

enum SecureChatConnectionState {
  idle,
  connecting,
  connected,
  reconnecting,
  offline,
  error,
}

class SecureChatConnectionSnapshot {
  final SecureChatConnectionState state;
  final String label;
  final DateTime updatedAt;

  const SecureChatConnectionSnapshot({
    required this.state,
    required this.label,
    required this.updatedAt,
  });

  bool get canAttemptPublish =>
      state == SecureChatConnectionState.connected ||
      state == SecureChatConnectionState.reconnecting;
}

class SentDirectMessageResult {
  final String eventId;
  final DateTime createdAt;

  const SentDirectMessageResult({
    required this.eventId,
    required this.createdAt,
  });
}

class RemoteConversationCommand {
  final String id;
  final String type;
  final String conversationId;
  final String senderPublicKey;
  final String recipientPublicKey;
  final DateTime createdAt;

  const RemoteConversationCommand({
    required this.id,
    required this.type,
    required this.conversationId,
    required this.senderPublicKey,
    required this.recipientPublicKey,
    required this.createdAt,
  });

  bool get isDeleteConversation => type == 'conversation_delete';
}

class NostrConnectionService {
  NostrConnectionService({
    required List<String> relayUrls,
    required NostrKeyPairs keyPair,
  })  : _relayUrls = relayUrls,
        _keyPair = keyPair;

  static const Duration _hardReconnectDelay = Duration(milliseconds: 650);
  static const Duration _connectTimeout = Duration(seconds: 12);
  static const Duration _publishTimeout = Duration(seconds: 12);
  static const Duration _softRefreshInterval = Duration(minutes: 2);

  final List<String> _relayUrls;
  final NostrKeyPairs _keyPair;
  final Nostr _nostr = Nostr.instance;

  final StreamController<SecureChatConnectionSnapshot> _statusController =
      StreamController<SecureChatConnectionSnapshot>.broadcast();
  final StreamController<MessageModel> _messageController =
      StreamController<MessageModel>.broadcast();
  final StreamController<RemoteConversationCommand> _commandController =
      StreamController<RemoteConversationCommand>.broadcast();

  StreamSubscription<NostrEvent>? _subscription;
  Timer? _maintenanceTimer;
  Future<void>? _connectionOperation;

  final Set<String> _seenIncomingEventIds = <String>{};

  bool _disposed = false;
  bool _hasSuccessfulConnect = false;
  DateTime? _lastSuccessfulConnectAt;

  Stream<SecureChatConnectionSnapshot> get statusStream =>
      _statusController.stream;

  Stream<MessageModel> get messageStream => _messageController.stream;

  Stream<RemoteConversationCommand> get commandStream =>
      _commandController.stream;

  SecureChatConnectionSnapshot _currentStatus = SecureChatConnectionSnapshot(
    state: SecureChatConnectionState.idle,
    label: 'Se initializeaza...',
    updatedAt: DateTime.now(),
  );

  SecureChatConnectionSnapshot get currentStatus => _currentStatus;

  Future<void> start() async {
    if (_disposed) return;
    await reconnect(reason: 'Initializare', force: true);
    _startMaintenanceTimer();
  }

  Future<void> reconnect({
    required String reason,
    bool force = true,
  }) async {
    if (_disposed) return;

    final activeOperation = _connectionOperation;
    if (activeOperation != null) {
      await activeOperation;
      return;
    }

    final operation = _doReconnect(reason: reason, force: force);
    _connectionOperation = operation;

    try {
      await operation;
    } finally {
      if (identical(_connectionOperation, operation)) {
        _connectionOperation = null;
      }
    }
  }

  Future<void> refreshIfNeeded({String reason = 'Refresh automat'}) async {
    if (_disposed) return;

    final lastConnect = _lastSuccessfulConnectAt;
    if (!_hasSuccessfulConnect || lastConnect == null) {
      await reconnect(reason: reason, force: true);
      return;
    }

    final elapsed = DateTime.now().difference(lastConnect);
    if (elapsed >= _softRefreshInterval) {
      await reconnect(reason: reason, force: true);
    }
  }

  Future<void> _doReconnect({
    required String reason,
    required bool force,
  }) async {
    if (_disposed) return;

    _emitStatus(
      _hasSuccessfulConnect
          ? SecureChatConnectionState.reconnecting
          : SecureChatConnectionState.connecting,
      _hasSuccessfulConnect ? '◌ Reconectare...' : '◌ Se conecteaza...',
    );

    try {
      await _subscription?.cancel();
      _subscription = null;

      if (force || _hasSuccessfulConnect) {
        try {
          _nostr.disconnect();
        } catch (_) {}
        await Future<void>.delayed(_hardReconnectDelay);
      }

      final result = await _nostr.connect(_relayUrls).timeout(_connectTimeout);

      result.fold(
        (_) {},
        (failure) {
          throw Exception(failure.message);
        },
      );

      _subscribeToMessagesForMe();

      _hasSuccessfulConnect = true;
      _lastSuccessfulConnectAt = DateTime.now();

      _emitStatus(
        SecureChatConnectionState.connected,
        '● Conectat',
      );
    } catch (_) {
      _hasSuccessfulConnect = false;
      _emitStatus(
        SecureChatConnectionState.offline,
        '○ Offline - reconectare necesara',
      );
      rethrow;
    }
  }

  void _subscribeToMessagesForMe() {
    final publicKey = _keyPair.public;
    if (publicKey.isEmpty) return;

    final request = NostrRequest(
      filters: [
        NostrFilter(
          kinds: [4],
          limit: 300,
          since: DateTime.now().subtract(const Duration(days: 31)),
        ),
      ],
    );

    final subResult = _nostr.subscribeRequest(request);

    subResult.fold(
      (eventsStream) {
        _subscription = eventsStream.stream.listen(
          _handleIncomingEvent,
          onError: (_) {
            _hasSuccessfulConnect = false;
            _emitStatus(
              SecureChatConnectionState.offline,
              '○ Stream inchis - reconectare...',
            );
            unawaited(reconnect(reason: 'Stream error', force: true));
          },
          onDone: () {
            _hasSuccessfulConnect = false;
            _emitStatus(
              SecureChatConnectionState.offline,
              '○ Stream inchis - reconectare...',
            );
            unawaited(reconnect(reason: 'Stream inchis', force: true));
          },
          cancelOnError: false,
        );
      },
      (failure) {
        throw Exception(failure.message);
      },
    );
  }

  void _handleIncomingEvent(NostrEvent event) {
    final publicKey = _keyPair.public;
    final tags = event.tags ?? [];

    var addressedToMe = false;
    for (final tag in tags) {
      if (tag.length >= 2 && tag[0] == 'p' && tag[1] == publicKey) {
        addressedToMe = true;
        break;
      }
    }

    if (!addressedToMe) return;

    final encrypted = (event.content ?? '').trim();
    if (encrypted.isEmpty) return;

    final eventId = _incomingEventId(event);
    if (_seenIncomingEventIds.contains(eventId)) return;
    _seenIncomingEventIds.add(eventId);

    try {
      final decrypted = Nip04.decrypt(
        encrypted,
        _keyPair.private,
        event.pubkey,
      );

      if (decrypted.trim().isEmpty) return;

      final peerPublicKey = event.pubkey;
      final conversationId = MessageModel.buildConversationId(
        publicKey,
        peerPublicKey,
      );
      const senderLabel = 'Contact necunoscut';
      final createdAt = _eventCreatedAt(event);
      final payload = _decodePayload(decrypted);

      if (payload.type == _VaultPayloadType.invalid) {
        return;
      }

      if (payload.type == _VaultPayloadType.deleteConversation) {
        if (!_commandController.isClosed) {
          _commandController.add(
            RemoteConversationCommand(
              id: eventId,
              type: 'conversation_delete',
              conversationId: conversationId,
              senderPublicKey: peerPublicKey,
              recipientPublicKey: publicKey,
              createdAt: createdAt,
            ),
          );
        }
        return;
      }

      final expiresAt = payload.ttlSeconds != null && payload.ttlSeconds! > 0
          ? createdAt.add(Duration(seconds: payload.ttlSeconds!))
          : null;

      if (expiresAt != null && !DateTime.now().isBefore(expiresAt)) {
        return;
      }

      if (!_messageController.isClosed) {
        _messageController.add(
          MessageModel(
            id: eventId,
            conversationId: conversationId,
            text: payload.text,
            isMine: false,
            senderLabel: senderLabel,
            senderPublicKey: peerPublicKey,
            recipientPublicKey: publicKey,
            peerPublicKey: peerPublicKey,
            createdAt: createdAt,
            isFromRelay: true,
            expiresAt: expiresAt,
          ),
        );
      }
    } catch (_) {
      // Evenimentele care nu pot fi decriptate pentru cheia curenta se ignora.
    }
  }

  Future<SentDirectMessageResult> publishDirectMessage({
    required String recipientPublicKey,
    required String plainText,
    int? ttlSeconds,
  }) async {
    if (_disposed) {
      throw StateError('NostrConnectionService este inchis.');
    }

    await refreshIfNeeded(reason: 'Pregatire trimitere');

    try {
      return await _publishOnce(
        recipientPublicKey: recipientPublicKey,
        plainText: plainText,
        ttlSeconds: ttlSeconds,
      );
    } catch (_) {
      await reconnect(reason: 'Publish retry', force: true);
      return _publishOnce(
        recipientPublicKey: recipientPublicKey,
        plainText: plainText,
        ttlSeconds: ttlSeconds,
      );
    }
  }


  Future<SentDirectMessageResult> publishDeleteConversationCommand({
    required String recipientPublicKey,
    required String conversationId,
  }) async {
    if (_disposed) {
      throw StateError('NostrConnectionService este inchis.');
    }

    await refreshIfNeeded(reason: 'Pregatire stergere remote');

    final payload = jsonEncode(<String, dynamic>{
      'v': 1,
      'type': 'conversation_delete',
      'conversationId': conversationId,
      'createdAtMillis': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      return await _publishRawPayload(
        recipientPublicKey: recipientPublicKey,
        payload: payload,
        fallbackSeed: 'delete|$conversationId',
      );
    } catch (_) {
      await reconnect(reason: 'Delete command retry', force: true);
      return _publishRawPayload(
        recipientPublicKey: recipientPublicKey,
        payload: payload,
        fallbackSeed: 'delete|$conversationId',
      );
    }
  }

  Future<SentDirectMessageResult> _publishRawPayload({
    required String recipientPublicKey,
    required String payload,
    required String fallbackSeed,
  }) async {
    final encrypted = Nip04.encrypt(
      payload,
      _keyPair.private,
      recipientPublicKey,
    );

    final event = NostrEvent.fromPartialData(
      kind: 4,
      content: encrypted,
      keyPairs: _keyPair,
      tags: [
        ['p', recipientPublicKey],
      ],
    );

    final result = await _nostr.publish(event).timeout(_publishTimeout);

    return result.fold(
      (_) {
        _hasSuccessfulConnect = true;
        _lastSuccessfulConnectAt = DateTime.now();
        _emitStatus(
          SecureChatConnectionState.connected,
          '● Conectat',
        );

        final directId = _readEventId(event);
        final createdAt = _eventCreatedAt(event);
        return SentDirectMessageResult(
          eventId: directId != null
              ? 'nostr_$directId'
              : 'local_cmd_${_stableHash('$recipientPublicKey|$fallbackSeed|${createdAt.millisecondsSinceEpoch}')}',
          createdAt: createdAt,
        );
      },
      (failure) {
        _hasSuccessfulConnect = false;
        _emitStatus(
          SecureChatConnectionState.offline,
          '○ Publish esuat - reconectare...',
        );
        throw Exception(failure.message);
      },
    );
  }

  Future<SentDirectMessageResult> _publishOnce({
    required String recipientPublicKey,
    required String plainText,
    int? ttlSeconds,
  }) async {
    final payload = _encodeTextPayload(plainText, ttlSeconds: ttlSeconds);
    final encrypted = Nip04.encrypt(
      payload,
      _keyPair.private,
      recipientPublicKey,
    );

    final event = NostrEvent.fromPartialData(
      kind: 4,
      content: encrypted,
      keyPairs: _keyPair,
      tags: [
        ['p', recipientPublicKey],
      ],
    );

    final result = await _nostr.publish(event).timeout(_publishTimeout);

    return result.fold(
      (_) {
        _hasSuccessfulConnect = true;
        _lastSuccessfulConnectAt = DateTime.now();
        _emitStatus(
          SecureChatConnectionState.connected,
          '● Conectat',
        );

        final eventId = _outgoingEventId(event, recipientPublicKey, plainText);
        return SentDirectMessageResult(
          eventId: eventId,
          createdAt: _eventCreatedAt(event),
        );
      },
      (failure) {
        _hasSuccessfulConnect = false;
        _emitStatus(
          SecureChatConnectionState.offline,
          '○ Publish esuat - reconectare...',
        );
        throw Exception(failure.message);
      },
    );
  }

  String _incomingEventId(NostrEvent event) {
    final directId = _readEventId(event);
    if (directId != null) return 'nostr_$directId';

    final encrypted = (event.content ?? '').trim();
    return 'nostr_fallback_${_stableHash('$encrypted|${event.pubkey}')}';
  }

  String _outgoingEventId(
    NostrEvent event,
    String recipientPublicKey,
    String plainText,
  ) {
    final directId = _readEventId(event);
    if (directId != null) return 'nostr_$directId';

    final createdAt = _eventCreatedAt(event).millisecondsSinceEpoch;
    return 'local_out_${_stableHash('$recipientPublicKey|$plainText|$createdAt')}';
  }

  String? _readEventId(NostrEvent event) {
    try {
      final dynamic rawId = (event as dynamic).id;
      if (rawId is String && rawId.trim().isNotEmpty) {
        return rawId.trim();
      }
    } catch (_) {}

    return null;
  }

  DateTime _eventCreatedAt(NostrEvent event) {
    try {
      final dynamic rawCreatedAt = (event as dynamic).createdAt;
      if (rawCreatedAt is DateTime) return rawCreatedAt;
      if (rawCreatedAt is int) {
        final isMillis = rawCreatedAt > 20000000000;
        return DateTime.fromMillisecondsSinceEpoch(
          isMillis ? rawCreatedAt : rawCreatedAt * 1000,
        );
      }
    } catch (_) {}

    return DateTime.now();
  }

  String _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }


  String _encodeTextPayload(String text, {int? ttlSeconds}) {
    return jsonEncode(<String, dynamic>{
      'v': 1,
      'type': 'text',
      'text': text,
      'createdAtMillis': DateTime.now().millisecondsSinceEpoch,
      if (ttlSeconds != null && ttlSeconds > 0) 'ttlSeconds': ttlSeconds,
    });
  }

  _VaultPayload _decodePayload(String decrypted) {
    final raw = decrypted.trim();
    if (raw.isEmpty) return const _VaultPayload.invalid();

    final decoded = _decodeProtocolJson(raw);
    if (decoded == null) {
      // Backward compatibility: mesajele vechi, trimise inainte de protocolul
      // JSON v1, raman afisabile ca text normal. In schimb, payload-urile care
      // arata ca JSON/protocol corupt NU se afiseaza brut in UI.
      if (_looksLikeProtocolPayload(raw)) {
        return const _VaultPayload.invalid();
      }
      return _VaultPayload.text(raw);
    }

    final type = (decoded['type'] ?? '').toString().trim();

    if (type == 'conversation_delete') {
      return const _VaultPayload.deleteConversation();
    }

    if (type == 'text') {
      final text = (decoded['text'] ?? '').toString();
      final ttlRaw = decoded['ttlSeconds'];
      final ttlSeconds = ttlRaw is int ? ttlRaw : int.tryParse('$ttlRaw');
      return _VaultPayload.text(text, ttlSeconds: ttlSeconds);
    }

    return const _VaultPayload.invalid();
  }

  Map<String, dynamic>? _decodeProtocolJson(String raw) {
    Object? decoded;

    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = null;
    }

    // Unele payload-uri pot ajunge ca string JSON dublu-encodat, de forma:
    // "{\"v\":1,\"type\":...}". Le decodam inca o data.
    if (decoded is String) {
      final inner = decoded.trim();
      if (inner.isEmpty) return null;
      try {
        decoded = jsonDecode(inner);
      } catch (_) {
        decoded = null;
      }
    }

    // Fallback defensiv pentru payload-uri cu ghilimele escapate, dar fara
    // ghilimele exterioare valide.
    if (decoded == null && raw.contains(r'"')) {
      final unescaped = raw.replaceAll(r'"', '"').trim();
      try {
        decoded = jsonDecode(unescaped);
      } catch (_) {
        decoded = null;
      }
    }

    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }

    return null;
  }

  bool _looksLikeProtocolPayload(String raw) {
    final value = raw.trimLeft();
    return value.startsWith('{') ||
        value.startsWith(r'{"') ||
        value.contains('"type"') ||
        value.contains(r'"type"') ||
        value.contains('conversation_delete') ||
        value.contains('ttlSeconds');
  }

  void _startMaintenanceTimer() {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(refreshIfNeeded(reason: 'Health check')),
    );
  }

  void _emitStatus(SecureChatConnectionState state, String label) {
    _currentStatus = SecureChatConnectionSnapshot(
      state: state,
      label: label,
      updatedAt: DateTime.now(),
    );

    if (!_statusController.isClosed) {
      _statusController.add(_currentStatus);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;

    await _subscription?.cancel();
    _subscription = null;

    try {
      _nostr.disconnect();
    } catch (_) {}

    await _statusController.close();
    await _messageController.close();
    await _commandController.close();
  }
}


enum _VaultPayloadType { text, deleteConversation, invalid }

class _VaultPayload {
  final _VaultPayloadType type;
  final String text;
  final int? ttlSeconds;

  const _VaultPayload._({
    required this.type,
    this.text = '',
    this.ttlSeconds,
  });

  const _VaultPayload.text(String text, {int? ttlSeconds})
      : this._(
          type: _VaultPayloadType.text,
          text: text,
          ttlSeconds: ttlSeconds,
        );

  const _VaultPayload.deleteConversation()
      : this._(type: _VaultPayloadType.deleteConversation);

  const _VaultPayload.invalid()
      : this._(type: _VaultPayloadType.invalid);
}
