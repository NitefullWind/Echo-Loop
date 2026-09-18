/// 外部 AI 配置与系统安全存储。
library;

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/external_ai_settings.dart';
import 'app_logger.dart';

const _settingsKey = 'external_ai_settings_v1';
const _keyPrefix = 'external_ai_key_';

/// 配置与凭据的持久化边界；先写新凭据，再原子切换配置引用。
/// 写入失败保留原配置，API Key 不进入普通偏好设置或日志。
class ExternalAiSettingsStore {
  ExternalAiSettingsStore({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? preferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferences;

  /// 读取已提交配置；损坏或缺失的凭据由上层展示恢复入口。
  Future<ExternalAiSettings> load() async {
    final prefs = await _preferences();
    final raw = prefs.getString(_settingsKey);
    if (raw == null) return const ExternalAiSettings();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid AI settings');
    }
    final provider = ExternalAiProvider.values
        .where((value) => value.name == decoded['provider'])
        .firstOrNull;
    if (provider == null) throw const FormatException('Unknown AI provider');
    if (provider == ExternalAiProvider.echoLoop) {
      return const ExternalAiSettings();
    }
    final baseUrl = decoded['baseUrl'];
    final model = decoded['model'];
    final keyRef = decoded['keyRef'];
    if (baseUrl is! String ||
        model is! String ||
        keyRef is! String ||
        !keyRef.startsWith(_keyPrefix)) {
      throw const FormatException('Incomplete AI settings');
    }
    final key = await _secureStorage.read(key: keyRef) ?? '';
    final settings = ExternalAiSettings(
      provider: provider,
      baseUrl: baseUrl,
      model: model,
      apiKey: key,
    );
    if (!settings.isConfigured) {
      throw const FormatException('AI credentials unavailable');
    }
    return settings;
  }

  /// 提交后才清理旧凭据，允许用户覆盖损坏的配置以恢复使用。
  Future<void> save(ExternalAiSettings settings) async {
    final prefs = await _preferences();
    final previous = prefs.getString(_settingsKey);
    final oldKey = _previousKey(previous);
    final external = settings.provider != ExternalAiProvider.echoLoop;
    final keyRef = '$_keyPrefix${const Uuid().v4()}';
    if (external) {
      await _secureStorage.write(key: keyRef, value: settings.apiKey);
    }
    try {
      final saved = await prefs.setString(
        _settingsKey,
        jsonEncode({
          'provider': settings.provider.name,
          'baseUrl': settings.baseUrl,
          'model': settings.model,
          if (external) 'keyRef': keyRef,
        }),
      );
      if (!saved) throw StateError('AI settings could not be saved');
    } catch (_) {
      if (external) await _deleteUnusedKey(keyRef);
      // SharedPreferences 先更新内存再提交平台，失败时必须恢复磁盘快照。
      await prefs.reload();
      rethrow;
    }
    if (oldKey is String) await _deleteUnusedKey(oldKey);
  }

  /// 备份中的配置仅能引用本功能的凭据，不能借清理操作删除其它登录态。
  String? _previousKey(String? raw) {
    if (raw == null) return null;
    try {
      final record = jsonDecode(raw);
      final key = record is Map<String, Object?> ? record['keyRef'] : null;
      return key is String && key.startsWith(_keyPrefix) ? key : null;
    } on FormatException {
      AppLogger.log('ExternalAI', '覆盖损坏的 AI 设置，无法定位旧凭据');
      return null;
    }
  }

  Future<void> _deleteUnusedKey(String key) async {
    try {
      await _secureStorage.delete(key: key);
    } catch (_) {
      AppLogger.log('ExternalAI', '清理不再使用的安全存储凭据失败');
    }
  }
}
