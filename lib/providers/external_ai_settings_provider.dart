/// 用户自定义 AI 服务设置的唯一状态入口。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/external_ai_settings.dart';
import '../services/external_ai_settings_store.dart';
import '../services/app_logger.dart';

export '../models/external_ai_settings.dart';
export '../services/external_ai_settings_store.dart';

final externalAiSettingsStoreProvider = Provider<ExternalAiSettingsStore>(
  (ref) => ExternalAiSettingsStore(),
);

/// 外部 AI 设置的唯一修改入口。
class ExternalAiSettingsController extends Notifier<ExternalAiSettings> {
  var _loadGeneration = 0;
  bool _disposed = false;
  bool _saving = false;
  late Future<void> ready;

  @override
  ExternalAiSettings build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      ++_loadGeneration;
    });
    ready = Future<void>.microtask(_load);
    return const ExternalAiSettings(isLoading: true);
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final settings = await ref.read(externalAiSettingsStoreProvider).load();
      if (_disposed || generation != _loadGeneration) return;
      state = settings;
    } catch (_) {
      if (_disposed || generation != _loadGeneration) return;
      state = const ExternalAiSettings(
        loadError:
            'Unable to load AI settings. Open External AI settings to retry.',
      );
      AppLogger.log('ExternalAI', '读取 AI 设置失败，已阻止 AI 请求');
    }
  }

  /// 用户主动重试失败的加载，防止旧加载覆盖新保存。
  Future<void> reload() {
    if (_saving) return ready;
    state = const ExternalAiSettings(isLoading: true);
    return ready = _load();
  }

  /// 保存设置。API Key 为空时保留已保存的 Key，便于用户只修改模型。
  Future<void> save({
    required ExternalAiProvider provider,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    if (_saving) throw StateError('AI settings are being saved');
    await ready;
    if (_saving) throw StateError('AI settings are being saved');
    if (_disposed) return;
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = model.trim();
    final enteredApiKey = apiKey?.trim() ?? '';
    final sameService =
        provider == state.provider && normalizedBaseUrl == state.baseUrl.trim();
    final resolvedApiKey = enteredApiKey.isEmpty && sameService
        ? state.apiKey
        : enteredApiKey;
    if (provider != ExternalAiProvider.echoLoop &&
        (normalizedBaseUrl.isEmpty ||
            normalizedModel.isEmpty ||
            resolvedApiKey.isEmpty)) {
      throw const FormatException('外部 AI 服务的地址、模型和 API Key 不能为空');
    }

    final next = ExternalAiSettings(
      provider: provider,
      baseUrl: normalizedBaseUrl,
      model: normalizedModel,
      apiKey: provider == ExternalAiProvider.echoLoop ? '' : resolvedApiKey,
    );

    if (provider != ExternalAiProvider.echoLoop && !next.isConfigured) {
      throw const FormatException('请输入有效的 HTTP(S) Base URL、模型和 API Key');
    }
    _saving = true;
    final generation = ++_loadGeneration;
    try {
      await ref.read(externalAiSettingsStoreProvider).save(next);
      if (!_disposed && generation == _loadGeneration) state = next;
    } finally {
      _saving = false;
    }
  }

  /// 切回 Echo Loop 后端，并删除用户 Key。
  Future<void> disable() => save(
    provider: ExternalAiProvider.echoLoop,
    baseUrl: state.baseUrl,
    model: state.model,
  );
}

/// 外部 AI 设置 Provider。
final externalAiSettingsProvider =
    NotifierProvider<ExternalAiSettingsController, ExternalAiSettings>(
      ExternalAiSettingsController.new,
    );
