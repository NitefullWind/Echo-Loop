import 'dart:async';
import 'dart:convert';
import 'package:echo_loop/providers/external_speech_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

class _Store extends Mock implements ExternalSpeechSettingsStore {}

class _Preferences extends Mock implements SharedPreferences {}

const settings = ExternalSpeechSettings(
  config: ExternalSpeechConfig(
    provider: ExternalSpeechProvider.aliyun,
    endpoint: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference',
    model: 'paraformer-realtime-v2',
    apiKey: 'private-key',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const ExternalSpeechSettings()));
  test('损坏的旧配置可以通过重新保存恢复', () async {
    SharedPreferences.setMockInitialValues({
      'external_speech_settings_v1': '{broken',
    });
    final store = ExternalSpeechSettingsStore(secureStorage: _Storage());
    await expectLater(store.load(), throwsFormatException);
    await store.save(const ExternalSpeechSettings());
    expect(
      (await store.load()).config.provider,
      ExternalSpeechProvider.disabled,
    );
  });

  test('配置不得读取或删除其它功能的安全存储 Key', () async {
    SharedPreferences.setMockInitialValues({
      'external_speech_settings_v1': jsonEncode({
        'provider': 'aliyun',
        'endpoint': settings.config.endpoint,
        'appId': '',
        'model': settings.config.model,
        'keyRef': 'unrelated_session',
      }),
    });
    final storage = _Storage();
    final store = ExternalSpeechSettingsStore(secureStorage: storage);
    await expectLater(store.load(), throwsFormatException);
    await store.save(const ExternalSpeechSettings());
    verifyZeroInteractions(storage);
  });

  test('偏好设置提交失败保留原凭据并清理新凭据', () async {
    final prefs = _Preferences();
    final storage = _Storage();
    final previous = jsonEncode({
      'provider': 'aliyun',
      'endpoint': settings.config.endpoint,
      'appId': '',
      'model': settings.config.model,
      'keyRef': 'external_speech_key_previous',
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
      () => storage.read(key: 'external_speech_key_previous'),
    ).thenAnswer((_) async => 'old-key');
    final store = ExternalSpeechSettingsStore(
      secureStorage: storage,
      preferences: () async => prefs,
    );
    await expectLater(store.save(settings), throwsStateError);
    expect((await store.load()).config.apiKey, 'old-key');
    verifyNever(() => storage.delete(key: 'external_speech_key_previous'));
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
    final store = ExternalSpeechSettingsStore(secureStorage: storage);
    await store.save(settings);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().map(prefs.get).join(),
      isNot(contains('private-key')),
    );
    final restored = await ExternalSpeechSettingsStore(
      secureStorage: storage,
    ).load();
    expect(restored.config.apiKey, 'private-key');
    expect(restored.config.endpoint, settings.config.endpoint);
    await store.save(const ExternalSpeechSettings());
    expect(keys, isEmpty);
    expect(
      (await store.load()).config.provider,
      ExternalSpeechProvider.disabled,
    );
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
    final store = ExternalSpeechSettingsStore(secureStorage: storage);
    await expectLater(store.save(settings), throwsStateError);
    expect(
      (await store.load()).config.provider,
      ExternalSpeechProvider.disabled,
    );
  });

  test('恢复备份缺少设备凭据时保留服务配置供重新补填', () async {
    SharedPreferences.setMockInitialValues({
      'external_speech_settings_v1': jsonEncode({
        'provider': 'doubao',
        'endpoint': '',
        'model': 'volc.bigasr.auc_turbo',
        'appId': 'legacy-app',
        'keyRef': 'external_speech_key_missing',
      }),
    });
    final storage = _Storage();
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => null);
    final restored = await ExternalSpeechSettingsStore(
      secureStorage: storage,
    ).load();
    expect(restored.config.provider, ExternalSpeechProvider.doubao);
    expect(restored.config.appId, 'legacy-app');
    expect(restored.isConfigured, isFalse);
    expect(restored.loadError, isNull);
  });

  test('仅修改模型保留Key，但服务、地址或豆包身份变更必须重填', () async {
    final store = _Store();
    when(store.load).thenAnswer((_) async => settings);
    when(() => store.save(any())).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [externalSpeechSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(externalSpeechSettingsProvider.notifier);
    await controller.ready;
    await controller.save(
      config: const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.aliyun,
        model: 'new-model',
      ),
    );
    expect(
      container.read(externalSpeechSettingsProvider).config.apiKey,
      'private-key',
    );
    expect(
      container.read(externalSpeechSettingsProvider).config.model,
      'new-model',
    );
    for (final config in [
      const ExternalSpeechConfig(provider: ExternalSpeechProvider.doubao),
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.aliyun,
        endpoint: 'wss://other.example/ws',
      ),
    ]) {
      await expectLater(controller.save(config: config), throwsFormatException);
    }
    await controller.save(
      config: const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.doubao,
        apiKey: 'new-key',
      ),
    );
    expect(container.read(externalSpeechSettingsProvider).isConfigured, isTrue);
    await expectLater(
      controller.save(
        config: const ExternalSpeechConfig(
          provider: ExternalSpeechProvider.doubao,
          appId: 'legacy-app',
        ),
      ),
      throwsFormatException,
    );
    verify(() => store.save(any())).called(2);
  });

  test('持久化失败不启用新配置，加载失败显式阻止请求并允许重试', () async {
    final store = _Store();
    when(store.load).thenThrow(StateError('locked'));
    final container = ProviderContainer(
      overrides: [externalSpeechSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(externalSpeechSettingsProvider.notifier);
    await controller.ready;
    expect(container.read(externalSpeechSettingsProvider).loadError, isNotNull);
    expect(
      container.read(externalSpeechSettingsProvider).isConfigured,
      isFalse,
    );
    when(store.load).thenAnswer((_) async => settings);
    await controller.reload();
    when(() => store.save(any())).thenThrow(StateError('write failed'));
    await expectLater(
      controller.save(
        config: const ExternalSpeechConfig(
          provider: ExternalSpeechProvider.aliyun,
          model: 'new-model',
        ),
      ),
      throwsStateError,
    );
    expect(
      container.read(externalSpeechSettingsProvider).config.model,
      settings.config.model,
    );
    expect(container.read(externalSpeechSettingsProvider).isConfigured, isTrue);
  });

  test('迟到的旧读取不会覆盖新读取结果', () async {
    final first = Completer<ExternalSpeechSettings>();
    final started = Completer<void>();
    final store = _Store();
    when(store.load).thenAnswer((_) {
      started.complete();
      return first.future;
    });
    final container = ProviderContainer(
      overrides: [externalSpeechSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(externalSpeechSettingsProvider.notifier);
    final initial = controller.ready;
    await started.future;
    when(store.load).thenAnswer((_) async => settings);
    await controller.reload();
    first.complete(const ExternalSpeechSettings());
    await initial;
    expect(container.read(externalSpeechSettingsProvider).isConfigured, isTrue);
  });
}
