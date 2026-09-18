import 'dart:async';
import 'dart:convert';

import 'package:echo_loop/features/auth/providers/auth_providers.dart';
import 'package:echo_loop/features/chatbot/providers/chat_api_client_provider.dart';
import 'package:echo_loop/features/chatbot/services/chat_api_client.dart';
import 'package:echo_loop/providers/external_ai_settings_provider.dart';
import 'package:echo_loop/services/openai_compatible_ai_client.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

class _Store extends Mock implements ExternalAiSettingsStore {}

class _Preferences extends Mock implements SharedPreferences {}

const settings = ExternalAiSettings(
  provider: ExternalAiProvider.custom,
  baseUrl: 'https://example.com/v1',
  model: 'model',
  apiKey: 'private-key',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('配置加载和失败期间不回退内部服务，恢复后句子与聊天同步切换', () async {
    final pending = Completer<ExternalAiSettings>();
    final store = _Store();
    when(store.load).thenAnswer((_) => pending.future);
    final container = ProviderContainer(
      overrides: [
        externalAiSettingsStoreProvider.overrideWithValue(store),
        supabaseTokenCoordinatorProvider.overrideWith((ref) {
          throw StateError('不得初始化内部鉴权');
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(externalAiSettingsProvider.notifier);
    final loadingClient = container.read(sentenceAiApiClientProvider);
    expect(loadingClient.usesExternalProvider, true);
    expect(container.read(chatApiClientProvider), isA<UnavailableChatApi>());
    await expectLater(
      loadingClient
          .translateStream('Hello', accessToken: '', targetLanguage: 'zh')
          .toList(),
      throwsA(isA<ExternalAiResponseException>()),
    );
    pending.completeError(StateError('storage locked'));
    await controller.ready;
    expect(
      container.read(sentenceAiApiClientProvider).usesExternalProvider,
      true,
    );
    expect(container.read(chatApiClientProvider), isA<UnavailableChatApi>());
    when(store.load).thenAnswer((_) async => settings);
    await controller.reload();
    expect(
      container.read(sentenceAiApiClientProvider).cacheNamespace,
      contains('external:'),
    );
    expect(
      container.read(chatApiClientProvider),
      isA<OpenAiCompatibleChatApi>(),
    );
  });

  test('损坏的旧配置可以通过重新保存恢复', () async {
    SharedPreferences.setMockInitialValues({
      'external_ai_settings_v1': '{broken',
    });
    final store = ExternalAiSettingsStore(secureStorage: _Storage());
    await expectLater(store.load(), throwsFormatException);
    await store.save(const ExternalAiSettings());
    expect((await store.load()).provider, ExternalAiProvider.echoLoop);
  });

  test('配置不得读取或删除其它功能的安全存储 Key', () async {
    SharedPreferences.setMockInitialValues({
      'external_ai_settings_v1': jsonEncode({
        'provider': 'custom',
        'baseUrl': settings.baseUrl,
        'model': settings.model,
        'keyRef': 'unrelated_session',
      }),
    });
    final storage = _Storage();
    final store = ExternalAiSettingsStore(secureStorage: storage);
    await expectLater(store.load(), throwsFormatException);
    await store.save(const ExternalAiSettings());
    verifyZeroInteractions(storage);
  });

  test('偏好设置提交失败保留原凭据并清理新凭据', () async {
    final prefs = _Preferences();
    final storage = _Storage();
    final previous = jsonEncode({
      'provider': 'custom',
      'baseUrl': settings.baseUrl,
      'model': settings.model,
      'keyRef': 'external_ai_key_previous',
    });
    var cachedRecord = previous;
    when(() => prefs.getString(any())).thenAnswer((_) => cachedRecord);
    when(() => prefs.setString(any(), any())).thenAnswer((call) async {
      final value = call.positionalArguments[1];
      if (value is String) cachedRecord = value;
      return false;
    });
    when(prefs.reload).thenAnswer((_) async => cachedRecord = previous);
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((_) async {});
    when(
      () => storage.read(key: 'external_ai_key_previous'),
    ).thenAnswer((_) async => 'old-key');
    final store = ExternalAiSettingsStore(
      secureStorage: storage,
      preferences: () async => prefs,
    );
    await expectLater(store.save(settings), throwsStateError);
    expect((await store.load()).apiKey, 'old-key');
    verifyNever(() => storage.delete(key: 'external_ai_key_previous'));
    verify(() => storage.delete(key: any(named: 'key'))).called(1);
  });

  test('重启恢复配置，Key 仅在安全存储；禁用会删除 Key', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _Storage();
    final keys = <String, String>{};
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((call) async {
      final key = call.namedArguments[#key];
      final value = call.namedArguments[#value];
      if (key is String && value is String) keys[key] = value;
    });
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((call) async => keys[call.namedArguments[#key]]);
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((call) async {
      keys.remove(call.namedArguments[#key]);
    });
    final store = ExternalAiSettingsStore(secureStorage: storage);
    await store.save(settings);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().map(prefs.get).join(),
      isNot(contains('private-key')),
    );
    final restored = await ExternalAiSettingsStore(
      secureStorage: storage,
    ).load();
    expect(restored.apiKey, 'private-key');
    expect(restored.baseUrl, settings.baseUrl);
    await store.save(const ExternalAiSettings());
    expect(keys, isEmpty);
    expect((await store.load()).provider, ExternalAiProvider.echoLoop);
  });

  test('安全存储写入失败保留原配置', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _Storage();
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenThrow(StateError('storage unavailable'));
    final store = ExternalAiSettingsStore(secureStorage: storage);
    await expectLater(store.save(settings), throwsStateError);
    expect((await store.load()).provider, ExternalAiProvider.echoLoop);
  });

  test('加载失败必须显式阻止请求，重试后可恢复', () async {
    final store = _Store();
    when(store.load).thenThrow(StateError('secure storage locked'));
    final container = ProviderContainer(
      overrides: [externalAiSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(externalAiSettingsProvider.notifier);
    expect(container.read(externalAiSettingsProvider).requestError, isNotNull);
    await controller.ready;
    expect(container.read(externalAiSettingsProvider).loadError, isNotNull);
    when(store.load).thenAnswer((_) async => settings);
    await controller.reload();
    expect(container.read(externalAiSettingsProvider).isConfigured, true);
  });

  test('持久化失败不启用新设置；更换服务不得复用旧 Key', () async {
    final store = _Store();
    when(store.load).thenAnswer((_) async => settings);
    final container = ProviderContainer(
      overrides: [externalAiSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(externalAiSettingsProvider.notifier);
    await controller.ready;
    await expectLater(
      controller.save(
        provider: ExternalAiProvider.custom,
        baseUrl: 'https://other.example',
        model: 'other',
      ),
      throwsFormatException,
    );
    registerFallbackValue(settings);
    when(() => store.save(any())).thenThrow(StateError('save failed'));
    await expectLater(
      controller.save(
        provider: settings.provider,
        baseUrl: settings.baseUrl,
        model: 'new-model',
      ),
      throwsStateError,
    );
    expect(container.read(externalAiSettingsProvider).model, 'model');
  });

  test('关闭容器后迟到的加载结果不会更新状态', () async {
    final pending = Completer<ExternalAiSettings>();
    final store = _Store();
    when(store.load).thenAnswer((_) => pending.future);
    final container = ProviderContainer(
      overrides: [externalAiSettingsStoreProvider.overrideWithValue(store)],
    );
    final controller = container.read(externalAiSettingsProvider.notifier);
    container.dispose();
    pending.complete(settings);
    await controller.ready;
  });
}
