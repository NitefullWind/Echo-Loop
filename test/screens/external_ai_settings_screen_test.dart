import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/external_ai_settings_provider.dart';
import 'package:echo_loop/screens/external_ai_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Store extends Mock implements ExternalAiSettingsStore {}

void main() {
  testWidgets('选择 DeepSeek 自动填预设，保存成功后才启用配置', (tester) async {
    final store = _Store();
    when(store.load).thenAnswer((_) async => const ExternalAiSettings());
    registerFallbackValue(const ExternalAiSettings());
    when(() => store.save(any())).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [externalAiSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ExternalAiSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<ExternalAiProvider>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      defaultDeepSeekBaseUrl,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      defaultDeepSeekModel,
    );
    final keyField = find.byType(TextField).at(2);
    expect(tester.widget<TextField>(keyField).obscureText, true);
    await tester.enterText(keyField, 'private-key');
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(
      container.read(externalAiSettingsProvider).provider,
      ExternalAiProvider.deepSeek,
    );
    expect(container.read(externalAiSettingsProvider).apiKey, 'private-key');
    expect(find.text('外部 AI 设置已保存'), findsOneWidget);
  });

  testWidgets('存储失败显示错误，不启用表单中的新模型', (tester) async {
    const settings = ExternalAiSettings(
      provider: ExternalAiProvider.custom,
      baseUrl: 'https://example.com/v1',
      model: 'old-model',
      apiKey: 'saved-key',
    );
    final store = _Store();
    when(store.load).thenAnswer((_) async => settings);
    registerFallbackValue(settings);
    when(() => store.save(any())).thenThrow(StateError('storage unavailable'));
    final container = ProviderContainer(
      overrides: [externalAiSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ExternalAiSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'new-model');
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(container.read(externalAiSettingsProvider).model, 'old-model');
    expect(
      find.text('Could not save AI settings. Check secure storage and retry.'),
      findsOneWidget,
    );
    expect(find.text('External AI settings saved'), findsNothing);
  });
}
