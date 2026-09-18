/// 外部语音设置的唯一状态入口。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/external_speech_settings.dart';
import '../services/external_speech_settings_store.dart';
import '../services/app_logger.dart';
export '../models/external_speech_settings.dart';
export '../services/external_speech_settings_store.dart';

final externalSpeechSettingsStoreProvider =
    Provider<ExternalSpeechSettingsStore>(
      (ref) => ExternalSpeechSettingsStore(),
    );

/// 串行保存并隔离过期加载，避免旧凭据污染新配置。
class ExternalSpeechSettingsController
    extends Notifier<ExternalSpeechSettings> {
  var _generation = 0;
  var _disposed = false;
  var _saving = false;
  late Future<void> ready;

  @override
  ExternalSpeechSettings build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      ++_generation;
    });
    ready = Future<void>.microtask(_load);
    return const ExternalSpeechSettings(isLoading: true);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final settings = await ref
          .read(externalSpeechSettingsStoreProvider)
          .load();
      if (!_disposed && generation == _generation) state = settings;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      state = const ExternalSpeechSettings(
        loadError:
            'Unable to load speech settings. Retry or enter a new configuration.',
      );
      AppLogger.log('ExternalSpeech', '读取语音设置失败，已阻止语音请求');
    }
  }

  /// 主动重试加载；保存过程中不发起竞争读取。
  Future<void> reload() {
    if (_saving) return ready;
    state = const ExternalSpeechSettings(isLoading: true);
    return ready = _load();
  }

  /// 空 Key 仅在同服务同地址时复用，跨服务或地址必须重新输入。
  Future<void> save({required ExternalSpeechConfig config}) async {
    if (_saving) throw StateError('Speech settings are being saved');
    await ready;
    if (_saving) throw StateError('Speech settings are being saved');
    if (_disposed) return;
    final endpoint = config.endpoint.trim().isEmpty
        ? externalSpeechDefaultEndpoint(config.provider)
        : config.endpoint.trim();
    final oldEndpoint = state.config.endpoint.trim().isEmpty
        ? externalSpeechDefaultEndpoint(state.config.provider)
        : state.config.endpoint.trim();
    final sameService =
        config.provider == state.config.provider &&
        endpoint == oldEndpoint &&
        config.appId.trim() == state.config.appId.trim();
    final enteredKey = config.apiKey.trim();
    final nextConfig = config.provider == ExternalSpeechProvider.disabled
        ? const ExternalSpeechConfig(provider: ExternalSpeechProvider.disabled)
        : ExternalSpeechConfig(
            provider: config.provider,
            endpoint: endpoint,
            model: config.model.trim().isEmpty
                ? externalSpeechDefaultModel(config.provider)
                : config.model.trim(),
            appId: config.appId.trim(),
            apiKey: enteredKey.isEmpty && sameService
                ? state.config.apiKey
                : enteredKey,
          );
    if (nextConfig.provider != ExternalSpeechProvider.disabled &&
        !nextConfig.isConfigured) {
      throw const FormatException('请输入有效的服务地址、模型与凭据');
    }
    final next = ExternalSpeechSettings(config: nextConfig);
    _saving = true;
    final generation = ++_generation;
    try {
      await ref.read(externalSpeechSettingsStoreProvider).save(next);
      if (!_disposed && generation == _generation) state = next;
    } finally {
      _saving = false;
    }
  }
}

final externalSpeechSettingsProvider =
    NotifierProvider<ExternalSpeechSettingsController, ExternalSpeechSettings>(
      ExternalSpeechSettingsController.new,
    );
