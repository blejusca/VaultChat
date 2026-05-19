class ContactModel {
  final String publicKey;
  final String displayName;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ContactModel({
    required this.publicKey,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
  });

  String get shortKey {
    if (publicKey.length >= 8) return publicKey.substring(0, 8);
    return publicKey;
  }

  String get label {
    final name = displayName.trim();
    return name.isNotEmpty ? name : shortKey;
  }

  Map<String, dynamic> toMap() {
    return {
      'publicKey': publicKey,
      'displayName': displayName,
      'createdAtMillis': createdAt.millisecondsSinceEpoch,
      'updatedAtMillis': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ContactModel.fromMap(Map<dynamic, dynamic> map) {
    final createdAtMillis = map['createdAtMillis'];
    final updatedAtMillis = map['updatedAtMillis'];

    return ContactModel(
      publicKey: (map['publicKey'] ?? '').toString(),
      displayName: (map['displayName'] ?? '').toString(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAtMillis is int
            ? createdAtMillis
            : int.tryParse('$createdAtMillis') ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        updatedAtMillis is int
            ? updatedAtMillis
            : int.tryParse('$updatedAtMillis') ?? 0,
      ),
    );
  }

  ContactModel copyWith({
    String? publicKey,
    String? displayName,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ContactModel(
      publicKey: publicKey ?? this.publicKey,
      displayName: displayName ?? this.displayName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
