import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jlpt_vault/main.dart';

void main() {
  testWidgets('JLPT Vault app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const JlptVaultApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
