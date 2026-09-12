import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_loop/providers/listening_practice/listening_practice_provider.dart';
import 'package:echo_loop/router/app_router.dart';
import 'package:echo_loop/router/main_shell.dart';
import 'package:echo_loop/screens/player_screen.dart';

import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

class _GatedListeningPractice extends TestListeningPractice {
  final finishCompleter = Completer<void>();

  @override
  int beginStudyPage() => 1;

  @override
  Future<void> finishStudyPage({int? generation}) => finishCompleter.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS 边缘右滑退出音频随心听不等待异步收尾', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final player = _GatedListeningPractice();
    await pumpFullAppWithAudio(
      tester,
      overrides: [listeningPracticeProvider.overrideWith(() => player)],
    );

    final router = GoRouter.of(tester.element(find.byType(MainShell)));
    unawaited(router.push<void>(AppRoutes.audioPlayer('audio-1')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(CupertinoPageTransition), findsOneWidget);

    await tester.flingFrom(const Offset(1, 400), const Offset(520, 0), 1000);
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, AppRoutes.study);
    expect(player.finishCompleter.isCompleted, isFalse);

    player.finishCompleter.complete();
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpAndSettle();
  });
}
