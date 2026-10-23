import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/widgets/app_page_transitions.dart';

Future<void> _openRoute(WidgetTester tester,
    {bool reducedMotion = false,
    TargetPlatform platform = TargetPlatform.linux}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(
        platform: platform, pageTransitionsTheme: appPageTransitionsTheme),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: child!,
    ),
    home: Builder(
        builder: (context) => Scaffold(
                body: Column(children: [
              const TextField(),
              TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(appBar: AppBar(), body: const Text('Details')),
                      )),
                  child: const Text('Open')),
            ]))),
  ));
  await tester.enterText(find.byType(TextField), 'Retained draft');
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('routes animate and returning preserves the previous view state',
      (tester) async {
    await _openRoute(tester);
    final fade = tester.widget<FadeTransition>(find
        .ancestor(
          of: find.text('Details'),
          matching: find.byType(FadeTransition),
        )
        .first);
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Retained draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.iOS]) {
    testWidgets('reduced motion skips route movement on $platform',
        (tester) async {
      await _openRoute(tester, reducedMotion: true, platform: platform);
      expect(
          find.ancestor(
              of: find.text('Details'), matching: find.byType(SlideTransition)),
          findsNothing);
      expect(
          find.ancestor(
              of: find.text('Details'), matching: find.byType(FadeTransition)),
          findsNothing);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Retained draft'), findsOneWidget);
    });
  }
}
