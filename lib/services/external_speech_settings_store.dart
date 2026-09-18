/// 外部语音配置与设备安全存储。
library;

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/external_speech_settings.dart';
import 'app_logger.dart';

const _settingsKey = 'external_speech_settings_v1';
const _keyPrefix = 'external_speech_key_';

/// 先写新凭据，再提交引用；失败不覆盖旧配置，凭据不进入备份或日志。
class ExternalSpeechSettingsStore {
  ExternalSpeechSettingsStore({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? preferences,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferences;

  /// 缺失设备凭据时保留非敏感配置，允许恢复备份后直接补填。
  Future<ExternalSpeechSettings> load() async {
    final prefs = await _preferences();
    final raw = prefs.getString(_settingsKey);
    if (raw == null) return const ExternalSpeechSettings();
    final record = jsonDecode(raw);
    if (record is! Map<String, Object?>)
      throw const FormatException('Invalid speech settings');
    final provider = ExternalSpeechProvider.values
        .where((p) => p.name == record['provider'])
        .firstOrNull;
    if (provider == null)
      throw const FormatException('Unknown speech provider');
    if (provider == ExternalSpeechProvider.disabled)
      return const ExternalSpeechSettings();
    final endpoint = record['endpoint'];
    final model = record['model'];
    final appId = record['appId'];
    final keyRef = record['keyRef'];
    if (endpoint is! String ||
        model is! String ||
        appId is! String ||
        keyRef is! String ||
        !keyRef.startsWith(_keyPrefix)) {
      throw const FormatException('Incomplete speech settings');
    }
    final key = await _secureStorage.read(key: keyRef) ?? '';
    return ExternalSpeechSettings(
      config: ExternalSpeechConfig(
        provider: provider,
        endpoint: endpoint,
        model: model,
        appId: appId,
        apiKey: key,
      ),
    );
  }

  /// 仅在配置提交成功后清理旧凭据，安全存储失败保留旧引用。
  Future<void> save(ExternalSpeechSettings settings) async {
    final prefs = await _preferences();
    final oldKey = _previousKey(prefs.getString(_settingsKey));
    final config = settings.config;
    final enabled = config.provider != ExternalSpeechProvider.disabled;
    final keyRef = '$_keyPrefix${const Uuid().v4()}';
    if (enabled) await _secureStorage.write(key: keyRef, value: config.apiKey);
    try {
      final saved = await prefs.setString(
        _settingsKey,
        jsonEncode({
          'provider': config.provider.name,
          'endpoint': config.endpoint,
          'model': config.model,
          'appId': config.appId,
          if (enabled) 'keyRef': keyRef,
        }),
      );
      if (!saved) throw StateError('Speech settings could not be saved');
    } catch (_) {
      if (enabled) await _deleteUnusedKey(keyRef);
      await prefs.reload();
      rethrow;
    }
    if (oldKey != null) await _deleteUnusedKey(oldKey);
  }

  /// 只允许清理本功能凭据，避免备份内引用触及其它安全存储记录。
  String? _previousKey(String? raw) {
    if (raw == null) return null;
    try {
      final record = jsonDecode(raw);
      final key = record is Map<String, Object?> ? record['keyRef'] : null;
      return key is String && key.startsWith(_keyPrefix) ? key : null;
    } on FormatException {
      AppLogger.log('ExternalSpeech', '覆盖损坏的语音设置，无法定位旧凭据');
      return null;
    }
  }

  Future<void> _deleteUnusedKey(String key) async {
    try {
      await _secureStorage.delete(key: key);
    } catch (_) {
      AppLogger.log('ExternalSpeech', '清理不再使用的语音凭据失败');
    }
  }
}
