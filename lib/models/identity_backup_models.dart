import 'contact_model.dart';
import 'conversation_model.dart';
import 'message_model.dart';

class IdentityRestoreRequest {
  const IdentityRestoreRequest({
    required this.payload,
    required this.password,
  });

  final String payload;
  final String password;
}

class RestoredIdentityBackup {
  const RestoredIdentityBackup({
    required this.privateKey,
    required this.contacts,
    this.messages = const <MessageModel>[],
    this.conversations = const <ConversationModel>[],
  });

  final String privateKey;
  final List<ContactModel> contacts;
  final List<MessageModel> messages;
  final List<ConversationModel> conversations;
}

String normalizeVaultChatRestorePayload(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), '');
}
