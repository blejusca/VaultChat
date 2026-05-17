class ConversationModel {
  final String id;
  final String myPublicKey;
  final String peerPublicKey;
  final String peerLabel;
  final String lastMessageText;
  final DateTime updatedAt;
  final int unreadCount;

  const ConversationModel({
    required this.id,
    required this.myPublicKey,
    required this.peerPublicKey,
    required this.peerLabel,
    required this.lastMessageText,
    required this.updatedAt,
    required this.unreadCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'myPublicKey': myPublicKey,
      'peerPublicKey': peerPublicKey,
      'peerLabel': peerLabel,
      'lastMessageText': lastMessageText,
      'updatedAtMillis': updatedAt.millisecondsSinceEpoch,
      'unreadCount': unreadCount,
    };
  }

  factory ConversationModel.fromMap(Map<dynamic, dynamic> map) {
    final updatedAtMillis = map['updatedAtMillis'];

    return ConversationModel(
      id: (map['id'] ?? '').toString(),
      myPublicKey: (map['myPublicKey'] ?? '').toString(),
      peerPublicKey: (map['peerPublicKey'] ?? '').toString(),
      peerLabel: (map['peerLabel'] ?? '').toString(),
      lastMessageText: (map['lastMessageText'] ?? '').toString(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        updatedAtMillis is int
            ? updatedAtMillis
            : int.tryParse('$updatedAtMillis') ?? 0,
      ),
      unreadCount: map['unreadCount'] is int
          ? map['unreadCount'] as int
          : int.tryParse('${map['unreadCount'] ?? 0}') ?? 0,
    );
  }

  ConversationModel copyWith({
    String? id,
    String? myPublicKey,
    String? peerPublicKey,
    String? peerLabel,
    String? lastMessageText,
    DateTime? updatedAt,
    int? unreadCount,
  }) {
    return ConversationModel(
      id: id ?? this.id,
      myPublicKey: myPublicKey ?? this.myPublicKey,
      peerPublicKey: peerPublicKey ?? this.peerPublicKey,
      peerLabel: peerLabel ?? this.peerLabel,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      updatedAt: updatedAt ?? this.updatedAt,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}
