import 'dart:convert';
import '../services/file_transfer_service.dart';

class MessageModel {
  final String id;
  final String conversationId;
  final String text;
  final bool isMine;
  final String senderLabel;
  final String senderPublicKey;
  final String recipientPublicKey;
  final String peerPublicKey;
  /// The original Nostr event `created_at` (or relay-confirmed timestamp).
  /// This is the canonical timestamp used for sorting. Never overwritten by
  /// download time, decrypt time, save time, or UI insert time.
  final DateTime createdAt;
  /// Wall-clock time at which the client composed/sent the message.
  /// Persisted for diagnostics only; the UI always sorts by [createdAt].
  final DateTime? clientCreatedAt;
  final bool isFromRelay;
  final DateTime? expiresAt; // null = never

  const MessageModel({
    required this.id,
    required this.conversationId,
    required this.text,
    required this.isMine,
    required this.senderLabel,
    required this.senderPublicKey,
    required this.recipientPublicKey,
    required this.peerPublicKey,
    required this.createdAt,
    this.clientCreatedAt,
    required this.isFromRelay,
    this.expiresAt,
  });

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// Returns metadata if the message contains an encrypted file.
  AttachmentMeta? get attachment =>
      AttachmentMeta.tryFromMessageText(text);

  /// True if the message is an attached file/photo.
  bool get hasAttachment => attachment != null;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'text': text,
      'isMine': isMine,
      'senderLabel': senderLabel,
      'senderPublicKey': senderPublicKey,
      'recipientPublicKey': recipientPublicKey,
      'peerPublicKey': peerPublicKey,
      'createdAtMillis': createdAt.millisecondsSinceEpoch,
      'clientCreatedAtMillis': clientCreatedAt?.millisecondsSinceEpoch,
      'isFromRelay': isFromRelay,
      'expiresAtMillis': expiresAt?.millisecondsSinceEpoch,
    };
  }

  factory MessageModel.fromMap(Map<dynamic, dynamic> map) {
    final createdAtMillis = map['createdAtMillis'];
    final clientCreatedAtMillis = map['clientCreatedAtMillis'];
    final expiresAtMillis = map['expiresAtMillis'];

    final senderPublicKey = (map['senderPublicKey'] ?? '').toString();
    final recipientPublicKey = (map['recipientPublicKey'] ?? '').toString();
    final peerPublicKey = (map['peerPublicKey'] ?? '').toString();
    final isMine = map['isMine'] == true;

    return MessageModel(
      id: (map['id'] ?? '').toString(),
      conversationId: (map['conversationId'] ?? '').toString(),
      text: (map['text'] ?? '').toString(),
      isMine: isMine,
      senderLabel: (map['senderLabel'] ?? '').toString(),
      senderPublicKey: senderPublicKey,
      recipientPublicKey: recipientPublicKey,
      peerPublicKey: peerPublicKey.isNotEmpty
          ? peerPublicKey
          : (isMine ? recipientPublicKey : senderPublicKey),
      // Restore the original Nostr created_at — never let decode time replace it.
      createdAt: DateTime.fromMillisecondsSinceEpoch(_parseMillis(createdAtMillis)),
      clientCreatedAt: clientCreatedAtMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(_parseMillis(clientCreatedAtMillis))
          : null,
      isFromRelay: map['isFromRelay'] == true,
      expiresAt: expiresAtMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(_parseMillis(expiresAtMillis))
          : null,
    );
  }

  /// Safely parse a millis value that may arrive from Hive as int, double, or
  /// String (observed on Android 10 with older Hive adapter versions).
  static int _parseMillis(dynamic raw) {
    if (raw is int) return raw;
    if (raw is double) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  MessageModel copyWith({
    String? id,
    String? conversationId,
    String? text,
    bool? isMine,
    String? senderLabel,
    String? senderPublicKey,
    String? recipientPublicKey,
    String? peerPublicKey,
    DateTime? createdAt,
    DateTime? clientCreatedAt,
    bool clearClientCreatedAt = false,
    bool? isFromRelay,
    DateTime? expiresAt,
    bool clearExpiry = false,
  }) {
    return MessageModel(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      text: text ?? this.text,
      isMine: isMine ?? this.isMine,
      senderLabel: senderLabel ?? this.senderLabel,
      senderPublicKey: senderPublicKey ?? this.senderPublicKey,
      recipientPublicKey: recipientPublicKey ?? this.recipientPublicKey,
      peerPublicKey: peerPublicKey ?? this.peerPublicKey,
      createdAt: createdAt ?? this.createdAt,
      clientCreatedAt: clearClientCreatedAt
          ? null
          : (clientCreatedAt ?? this.clientCreatedAt),
      isFromRelay: isFromRelay ?? this.isFromRelay,
      expiresAt: clearExpiry ? null : (expiresAt ?? this.expiresAt),
    );
  }

  static String buildConversationId(String a, String b) {
    final first = a.trim().toLowerCase();
    final second = b.trim().toLowerCase();
    final sorted = [first, second]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}
