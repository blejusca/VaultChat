import 'package:hive_flutter/hive_flutter.dart';

import '../models/contact_model.dart';

class ContactStorageService {
  ContactStorageService._(this._contactsBox);

  static const String _contactsBoxName = 'vaultchat_contacts_v1';

  final Box _contactsBox;

  static Future<ContactStorageService> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox(_contactsBoxName);
    return ContactStorageService._(box);
  }

  static Future<void> deleteAllLocalData() async {
    await Hive.initFlutter();
    if (Hive.isBoxOpen(_contactsBoxName)) {
      await Hive.box(_contactsBoxName).close();
    }
    try {
      await Hive.deleteBoxFromDisk(_contactsBoxName);
    } catch (_) {}
  }

  String _normalizeKey(String publicKey) => publicKey.trim().toLowerCase();

  Future<void> upsertContact({
    required String publicKey,
    required String displayName,
  }) async {
    final normalizedKey = _normalizeKey(publicKey);
    final cleanName = displayName.trim();
    if (normalizedKey.isEmpty || cleanName.isEmpty) return;

    final now = DateTime.now();
    final existingRaw = _contactsBox.get(normalizedKey);
    final existing = existingRaw is Map
        ? ContactModel.fromMap(existingRaw)
        : null;

    final contact = ContactModel(
      publicKey: normalizedKey,
      displayName: cleanName,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    await _contactsBox.put(normalizedKey, contact.toMap());
  }

  Future<ContactModel?> getContact(String publicKey) async {
    final raw = _contactsBox.get(_normalizeKey(publicKey));
    if (raw is! Map) return null;
    final contact = ContactModel.fromMap(raw);
    if (contact.publicKey.trim().isEmpty) return null;
    return contact;
  }

  Future<List<ContactModel>> loadContacts() async {
    final contacts = <ContactModel>[];
    final invalidKeys = <dynamic>[];

    for (final key in _contactsBox.keys) {
      final raw = _contactsBox.get(key);
      if (raw is! Map) {
        invalidKeys.add(key);
        continue;
      }
      final contact = ContactModel.fromMap(raw);
      if (contact.publicKey.trim().isEmpty || contact.displayName.trim().isEmpty) {
        invalidKeys.add(key);
        continue;
      }
      contacts.add(contact);
    }

    for (final key in invalidKeys) {
      await _contactsBox.delete(key);
    }

    contacts.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return contacts;
  }

  Future<String?> displayNameFor(String publicKey) async {
    final contact = await getContact(publicKey);
    final name = contact?.displayName.trim();
    return name == null || name.isEmpty ? null : name;
  }

  Future<void> deleteContact(String publicKey) async {
    await _contactsBox.delete(_normalizeKey(publicKey));
  }

  Future<void> close() async {
    await _contactsBox.close();
  }
}
