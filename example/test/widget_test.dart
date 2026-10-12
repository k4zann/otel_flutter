import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter_example/main.dart';

void main() {
  testWidgets('home screen renders without Otel.init', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    expect(find.text('Traced work'), findsOneWidget);
    await tester.tap(find.text('Caught error'));
    await tester.pump();
    expect(find.text('Reported a caught FormatException.'), findsOneWidget);
  });
}
