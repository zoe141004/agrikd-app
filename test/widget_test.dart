import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/diagnosis/presentation/screens/home_screen.dart';
import 'package:app/providers/settings_provider.dart';
import 'package:app/data/database/app_database.dart';

import 'test_helper.dart';

void main() {
  setUpAll(() async {
    initTestDatabase();
    await resetTestDatabase();
    await AppDatabase.database;
    S.setLocale('en');
  });

  Future<ProviderContainer> createContainer() async {
    final container = ProviderContainer();
    await container.read(settingsProvider.notifier).loadAll();
    return container;
  }

  Widget buildApp(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.lightTheme, home: const HomeScreen()),
    );
  }

  testWidgets('HomeScreen renders app title', (WidgetTester tester) async {
    final container = await createContainer();

    await tester.pumpWidget(buildApp(container));
    // Use pump with short duration instead of pumpAndSettle (stats widget has
    // async operations that prevent settling).
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('AgriKD'), findsWidgets);

    container.dispose();
  });

  testWidgets('HomeScreen shows scan button', (WidgetTester tester) async {
    final container = await createContainer();

    await tester.pumpWidget(buildApp(container));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(S.get('scan')), findsWidgets);

    container.dispose();
  });

  testWidgets('HomeScreen shows bottom navigation', (
    WidgetTester tester,
  ) async {
    final container = await createContainer();

    await tester.pumpWidget(buildApp(container));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(S.get('nav_home')), findsWidgets);
    expect(find.text(S.get('nav_history')), findsOneWidget);
    expect(find.text(S.get('nav_settings')), findsOneWidget);

    container.dispose();
  });
}
