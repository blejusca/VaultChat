import 'package:flutter_test/flutter_test.dart';
import 'package:nostr_basic_app/main.dart';

void main() {
  testWidgets('App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const NostrBasicApp());
    expect(find.text('Nostr Basic App'), findsOneWidget);
  });
}
