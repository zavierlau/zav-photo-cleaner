import 'package:flutter_test/flutter_test.dart';
import 'package:photo_cleaner/main.dart' as app;

void main() {
  testWidgets('App builds', (tester) async {
    await tester.pumpWidget(const app.PhotoCleanerApp());
    expect(find.byType(app.PhotoCleanerApp), findsOneWidget);
  });
}