import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/external_speech_settings_provider.dart';
import 'package:echo_loop/screens/external_speech_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Store extends Mock implements ExternalSpeechSettingsStore {}

void main() {
  testWidgets('存储失败显示错误，不启用表单中的新模型', (tester) async {
    const settings = ExternalSpeechSettings(
      config: ExternalSpeechConfig(
        provider: ExternalSpeechProvider.aliyun,
        endpoint: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
        model: 'old-model',
        apiKey: 'saved-key',
      ),
    );
    final store = _Store();
    when(store.load).thenAnswer((_) async => settings);
    registerFallbackValue(settings);
    when(() => store.save(any())).thenThrow(StateError('storage unavailable'));
    final container = ProviderContainer(
      overrides: [externalSpeechSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ExternalSpeechSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'new-model');
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(
      container.read(externalSpeechSettingsProvider).config.model,
      'old-model',
    );
    expect(
      find.text(
        'Could not save. Check device secure storage and retry. Previous settings are preserved.',
      ),
      findsOneWidget,
    );
    expect(find.text('Speech settings saved'), findsNothing);
  });
}
