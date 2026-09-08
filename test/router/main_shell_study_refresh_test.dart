import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/startup_bootstrap_provider.dart';
import 'package:echo_loop/providers/study_stats_provider.dart';
import 'package:echo_loop/router/app_router.dart';
import 'package:echo_loop/router/main_shell.dart';
import 'package:echo_loop/services/study_time_service.dart';

class _PendingStartupController extends LocalStartupController {
  @override
  Future<StartupReport> build() => Completer<StartupReport>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late GoRouter router;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    router = GoRouter(
      navigatorKey: rootNavigatorKey,
      observers: [rootRouteObserver],
      initialLocation: '/study',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) =>
              MainShell(navigationShell: navigationShell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/collections',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Collections')),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/study',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Study')),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/favorites',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Favorites')),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/settings',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Settings')),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/free-player',
          parentNavigatorKey: rootNavigatorKey,
          builder: (context, state) =>
              const Scaffold(body: Text('Free Player')),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await database.close();
  });

  testWidgets('从根路由返回 Study 时刷新已落库的统计', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          localStartupProvider.overrideWith(_PendingStartupController.new),
        ],
        child: Consumer(
          builder: (context, ref, child) {
            final stats = ref.watch(studyStatsNotifierProvider).valueOrNull;
            return Directionality(
              textDirection: TextDirection.ltr,
              child: Stack(
                children: [
                  MaterialApp.router(
                    localizationsDelegates: const [
                      AppLocalizations.delegate,
                      GlobalMaterialLocalizations.delegate,
                      GlobalWidgetsLocalizations.delegate,
                      GlobalCupertinoLocalizations.delegate,
                    ],
                    supportedLocales: const [Locale('en'), Locale('zh')],
                    routerConfig: router,
                  ),
                  Positioned(
                    key: const ValueKey('study-stats-observer'),
                    left: 0,
                    top: 0,
                    child: Text('${stats?.todaySeconds ?? -1}'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('0'), findsOneWidget);

    await StudyTimeService(
      database.dailyStudyRecordDao,
      database.dailyStageStudyRecordDao,
    ).addStudyDuration(const Duration(seconds: 2));

    router.push('/free-player');
    await tester.pump();
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('2'), findsOneWidget);
  });
}
