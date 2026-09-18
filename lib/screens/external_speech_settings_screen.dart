/// 外部语音服务设置页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/external_speech_settings_provider.dart';

/// 配置阿里百炼或豆包的转录服务，凭据仅保存在当前设备。
class ExternalSpeechSettingsScreen extends ConsumerStatefulWidget {
  const ExternalSpeechSettingsScreen({super.key});

  @override
  ConsumerState<ExternalSpeechSettingsScreen> createState() =>
      _ExternalSpeechSettingsScreenState();
}

class _ExternalSpeechSettingsScreenState
    extends ConsumerState<ExternalSpeechSettingsScreen> {
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _appId = TextEditingController();
  late final ProviderSubscription<ExternalSpeechSettings> _subscription;
  ExternalSpeechProvider _provider = ExternalSpeechProvider.disabled;
  bool _dirty = false;
  bool _saving = false;
  bool _obscure = true;

  String _text(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    _subscription = ref.listenManual(externalSpeechSettingsProvider, (_, next) {
      if (!mounted || next.isLoading || next.loadError != null || _dirty)
        return;
      setState(() {
        _provider = next.config.provider;
        _endpoint.text = next.config.endpoint;
        _model.text = next.config.model;
        _appId.text = next.config.appId;
        _key.clear();
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _subscription.close();
    _endpoint.dispose();
    _model.dispose();
    _key.dispose();
    _appId.dispose();
    super.dispose();
  }

  /// 切换服务时清空输入凭据，默认地址与模型复用协议层定义。
  void _select(ExternalSpeechProvider? provider) {
    if (provider == null || provider == _provider) return;
    setState(() {
      _dirty = true;
      _provider = provider;
      _endpoint.text = externalSpeechDefaultEndpoint(provider);
      _model.text = externalSpeechDefaultModel(provider);
      _appId.clear();
      _key.clear();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(externalSpeechSettingsProvider.notifier)
          .save(
            config: ExternalSpeechConfig(
              provider: _provider,
              endpoint: _endpoint.text,
              model: _model.text,
              apiKey: _key.text,
              appId: _appId.text,
            ),
          );
      if (!mounted) return;
      _dirty = false;
      _key.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_text('语音设置已保存', 'Speech settings saved'))),
      );
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _text(
              '请检查服务地址、模型和凭据。更换服务或地址后需重新填写 Key；豆包新版控制台可不填 APP ID。',
              'Check the endpoint, model and credentials. APP ID is optional for the new Doubao console. Re-enter the key after changing services or endpoints.',
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _text(
              '无法保存，请检查设备安全存储后重试；原设置仍保留。',
              'Could not save. Check device secure storage and retry. Previous settings are preserved.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(externalSpeechSettingsProvider);
    final busy = _saving || settings.isLoading;
    final enabled = _provider != ExternalSpeechProvider.disabled;
    final doubao = _provider == ExternalSpeechProvider.doubao;
    return Scaffold(
      appBar: AppBar(title: Text(_text('外部语音服务', 'External speech'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (settings.isLoading) const LinearProgressIndicator(),
          if (settings.loadError != null) ...[
            Text(
              _text(
                '读取语音设置失败。请重试，或重新填写并保存。',
                'Could not load speech settings. Retry or enter and save a new configuration.',
              ),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => ref
                        .read(externalSpeechSettingsProvider.notifier)
                        .reload(),
              child: Text(_text('重试', 'Retry')),
            ),
          ],
          Text(
            _text(
              '使用自己的阿里百炼或豆包账号进行语音转录。复述评价使用外部 AI 设置中的模型。',
              'Use your own Alibaba Bailian or Doubao account for transcription. Retelling evaluation uses the model in External AI settings.',
            ),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<ExternalSpeechProvider>(
            key: ValueKey(_provider),
            initialValue: _provider,
            decoration: InputDecoration(labelText: _text('服务', 'Provider')),
            items: [
              DropdownMenuItem(
                value: ExternalSpeechProvider.disabled,
                child: Text(_text('未配置', 'Not configured')),
              ),
              DropdownMenuItem(
                value: ExternalSpeechProvider.aliyun,
                child: Text(_text('阿里百炼', 'Alibaba Bailian')),
              ),
              DropdownMenuItem(
                value: ExternalSpeechProvider.doubao,
                child: Text(_text('豆包', 'Doubao')),
              ),
            ],
            onChanged: busy ? null : _select,
          ),
          if (enabled) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _endpoint,
              enabled: !busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              onChanged: (_) => _dirty = true,
              decoration: InputDecoration(labelText: _text('服务地址', 'Endpoint')),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _model,
              enabled: !busy,
              autocorrect: false,
              onChanged: (_) => _dirty = true,
              decoration: InputDecoration(
                labelText: doubao ? 'Resource ID' : _text('模型', 'Model'),
              ),
            ),
            if (doubao) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _appId,
                enabled: !busy,
                autocorrect: false,
                onChanged: (_) => _dirty = true,
                decoration: InputDecoration(
                  labelText: 'APP ID',
                  hintText: _text(
                    '旧版控制台填写，新版留空',
                    'Enter for legacy console; leave blank for new API Key',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _key,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: _obscure,
              onChanged: (_) => _dirty = true,
              decoration: InputDecoration(
                labelText: doubao ? 'Access Token' : 'API Key',
                hintText: _text(
                  '同服务与地址下，留空保留已保存的 Key',
                  'Leave blank to keep the key for the same service and endpoint',
                ),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _text('显示或隐藏凭据', 'Show or hide credentials'),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _text(
                'Key 仅保存在本机安全存储，不随备份迁移；恢复备份后请重新填写。',
                'Keys remain in device secure storage and are not backed up. Re-enter them after restoring a backup.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _text(
                '转录时音频会发送至所选服务，并按服务商规则计费。',
                'Audio is sent to the selected provider for transcription and billed under its pricing.',
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_text('保存', 'Save')),
          ),
        ],
      ),
    );
  }
}
