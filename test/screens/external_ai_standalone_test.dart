import 'package:echo_loop/config/external_services_config.dart';
import 'package:echo_loop/features/chatbot/widgets/sentence_chat_button.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/external_ai_settings_provider.dart';
import 'package:echo_loop/screens/external_ai_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Store extends Mock implements ExternalAiSettingsStore {}

void main() {
  testWidgets('独立版旧官方配置显示自定义表单，聊天未配置转到设置', (tester) async {
    final store = _Store();
    when(store.load).thenAnswer((_) async => const ExternalAiSettings());
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
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSentenceChatbotSheet(
                  context: context,
                  sentenceText: 'Hello',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      shouldShowAiChatAssistantEntry(
        chatbotEnabled: false,
        remoteEnabled: false,
      ),
      isTrue,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(ExternalAiSettingsScreen), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    await tester.tap(find.byType(DropdownButtonFormField<ExternalAiProvider>));
    await tester.pumpAndSettle();
    expect(find.text('Echo Loop'), findsNothing);
    expect(find.text('DeepSeek'), findsWidgets);
  }, skip: !externalServicesOnly);
}
