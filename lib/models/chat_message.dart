class ChatMessage {
  final String id;
  final String text;
  final bool isMe;
  final String sender;
  final DateTime time;
  final String peerPublicKey;
  final String senderPublicKey;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.sender,
    required this.time,
    required this.peerPublicKey,
    required this.senderPublicKey,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'text': text,
      'isMe': isMe,
      'sender': sender,
      'timeMillis': time.millisecondsSinceEpoch,
      'peerPublicKey': peerPublicKey,
      'senderPublicKey': senderPublicKey,
    };
  }

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) {
    final timeMillis = map['timeMillis'];

    return ChatMessage(
      id: (map['id'] ?? '').toString(),
      text: (map['text'] ?? '').toString(),
      isMe: map['isMe'] == true,
      sender: (map['sender'] ?? '').toString(),
      time: DateTime.fromMillisecondsSinceEpoch(
        timeMillis is int ? timeMillis : int.tryParse('$timeMillis') ?? 0,
      ),
      peerPublicKey: (map['peerPublicKey'] ?? '').toString(),
      senderPublicKey: (map['senderPublicKey'] ?? '').toString(),
    );
  }
}
