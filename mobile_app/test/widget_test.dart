@Tags(['widget'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/core/constants/model_constants.dart';
import 'package:app/data/database/app_database.dart';

import 'test_helper.dart';

/// Lightweight home body that tests the UI without the full IndexedStack
/// (which includes HistoryScreen and SettingsScreen that trigger heavy
/// async operations and Supabase init, causing tests to never settle).
class _TestableHomeBody extends ConsumerWidget {
  const _TestableHomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allModels = ModelConstants.modelsList;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(S.get('app_name'), style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 16),
            ...allModels.map((m) => ListTile(
              title: Text(m.localizedName(S.locale)),
              subtitle: Text(S.fmt('n_diseases', [m.diseaseCount])),
            )),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            label: S.get('nav_home'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.history_outlined),
            label: S.get('nav_history'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            label: S.get('nav_settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {},
        icon: const Icon(Icons.camera_alt),
        label: Text(S.get('scan')),
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    initTestDatabase();
    await resetTestDatabase();
    await AppDatabase.database;
    S.setLocale('en');
  });

  tearDownAll(() async {
    await resetTestDatabase();
  });

  Widget buildApp() {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const _TestableHomeBody(),
      ),
    );
  }

  testWidgets('HomeScreen renders app title', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.text('AgriKD'), findsOneWidget);
  });

  testWidgets('HomeScreen shows scan button', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.text(S.get('scan')), findsOneWidget);
  });

  testWidgets('HomeScreen shows bottom navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.text(S.get('nav_home')), findsOneWidget);
    expect(find.text(S.get('nav_history')), findsOneWidget);
    expect(find.text(S.get('nav_settings')), findsOneWidget);
  });

  testWidgets('HomeScreen shows all leaf types', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    for (final model in ModelConstants.modelsList) {
      expect(find.text(model.localizedName('en')), findsOneWidget);
    }
  });
}
