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
  final DateTime createdAt;
  final bool isFromRelay;
  final DateTime? expiresAt; // NEW — null = never

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
      'isFromRelay': isFromRelay,
      'expiresAtMillis': expiresAt?.millisecondsSinceEpoch,
    };
  }

  factory MessageModel.fromMap(Map<dynamic, dynamic> map) {
    final createdAtMillis = map['createdAtMillis'];
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
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        // Handle double values from Hive on older Android (e.g. Android 10)
        createdAtMillis is int
            ? createdAtMillis
            : createdAtMillis is double
                ? createdAtMillis.toInt()
                : int.tryParse('$createdAtMillis') ?? 0,
      ),
      isFromRelay: map['isFromRelay'] == true,
      expiresAt: expiresAtMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(
              expiresAtMillis is int
                  ? expiresAtMillis
                  : expiresAtMillis is double
                      ? expiresAtMillis.toInt()
                      : int.tryParse('$expiresAtMillis') ?? 0,
            )
          : null,
    );
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
