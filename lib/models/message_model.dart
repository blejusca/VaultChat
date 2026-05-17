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
  });

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
    };
  }

  factory MessageModel.fromMap(Map<dynamic, dynamic> map) {
    final createdAtMillis = map['createdAtMillis'];

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
        createdAtMillis is int
            ? createdAtMillis
            : int.tryParse('$createdAtMillis') ?? 0,
      ),
      isFromRelay: map['isFromRelay'] == true,
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
    );
  }

  static String buildConversationId(String a, String b) {
    final first = a.trim().toLowerCase();
    final second = b.trim().toLowerCase();
    final sorted = [first, second]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}
