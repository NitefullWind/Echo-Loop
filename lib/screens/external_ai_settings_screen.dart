/// 外部 AI 服务设置页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/external_ai_settings_provider.dart';
import '../config/external_services_config.dart';
import '../l10n/app_localizations.dart';

/// 配置用户自己的 OpenAI-compatible 模型服务。
class ExternalAiSettingsScreen extends ConsumerStatefulWidget {
  const ExternalAiSettingsScreen({super.key});

  @override
  ConsumerState<ExternalAiSettingsScreen> createState() =>
      _ExternalAiSettingsScreenState();
}

class _ExternalAiSettingsScreenState
    extends ConsumerState<ExternalAiSettingsScreen> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _apiKeyController;
  late final ProviderSubscription<ExternalAiSettings> _settingsSubscription;
  ExternalAiProvider _provider = externalServicesOnly
      ? ExternalAiProvider.custom
      : ExternalAiProvider.echoLoop;
  bool _obscureApiKey = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController();
    _modelController = TextEditingController();
    _apiKeyController = TextEditingController();
    _settingsSubscription = ref.listenManual<ExternalAiSettings>(
      externalAiSettingsProvider,
      (_, next) => _applySettings(next),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _settingsSubscription.close();
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _applySettings(ExternalAiSettings settings) {
    if (!mounted ||
        settings.isLoading ||
        settings.loadError != null ||
        _dirty) {
      return;
    }
    setState(() {
      _provider =
          externalServicesOnly &&
              settings.provider == ExternalAiProvider.echoLoop
          ? ExternalAiProvider.custom
          : settings.provider;
      _baseUrlController.text = settings.baseUrl;
      _modelController.text = settings.model;
      _apiKeyController.clear();
    });
  }

  void _selectProvider(ExternalAiProvider? provider) {
    if (provider == null || provider == _provider) return;
    setState(() {
      _dirty = true;
      _provider = provider;
      _apiKeyController.clear();
      if (provider == ExternalAiProvider.openAi ||
          provider == ExternalAiProvider.deepSeek) {
        _baseUrlController.text = defaultBaseUrlFor(provider);
        _modelController.text = defaultModelFor(provider);
      } else if (provider == ExternalAiProvider.echoLoop ||
          provider == ExternalAiProvider.custom) {
        _baseUrlController.clear();
        _modelController.clear();
        if (provider == ExternalAiProvider.echoLoop) {
          _apiKeyController.clear();
        }
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(externalAiSettingsProvider.notifier)
          .save(
            provider: _provider,
            baseUrl: _baseUrlController.text,
            model: _modelController.text,
            apiKey: _apiKeyController.text,
          );
      if (!mounted) return;
      _dirty = false;
      _apiKeyController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (AppLocalizations.of(context) ??
                    lookupAppLocalizations(const Locale('en')))
                .externalAiSaved,
          ),
        ),
      );
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (AppLocalizations.of(context) ??
                    lookupAppLocalizations(const Locale('en')))
                .externalAiInvalid,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (AppLocalizations.of(context) ??
                    lookupAppLocalizations(const Locale('en')))
                .externalAiSaveFailed,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy =
        AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en'));
    final settings = ref.watch(externalAiSettingsProvider);
    final busy = _saving || settings.isLoading;
    final isEchoLoop = _provider == ExternalAiProvider.echoLoop;
    return Scaffold(
      appBar: AppBar(title: Text(copy.externalAiTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (settings.isLoading) const LinearProgressIndicator(),
          if (settings.loadError != null) ...[
            Text(copy.externalAiLoadFailed),
            TextButton(
              onPressed: busy
                  ? null
                  : () =>
                        ref.read(externalAiSettingsProvider.notifier).reload(),
              child: Text(copy.retry),
            ),
          ],
          Text(copy.externalAiDescription),
          const SizedBox(height: 20),
          DropdownButtonFormField<ExternalAiProvider>(
            key: ValueKey(_provider),
            initialValue: _provider,
            decoration: InputDecoration(labelText: copy.externalAiProvider),
            items: [
              for (final provider in ExternalAiProvider.values.where(
                (value) =>
                    !externalServicesOnly ||
                    value != ExternalAiProvider.echoLoop,
              ))
                DropdownMenuItem(
                  value: provider,
                  child: Text(
                    provider == ExternalAiProvider.custom
                        ? copy.externalAiCustom
                        : provider.label,
                  ),
                ),
            ],
            onChanged: busy ? null : _selectProvider,
          ),
          if (!isEchoLoop) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _baseUrlController,
              enabled: !busy,
              onChanged: (_) => _dirty = true,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: copy.externalAiBaseUrl,
                hintText: 'https://api.example.com/v1',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _modelController,
              enabled: !busy,
              onChanged: (_) => _dirty = true,
              autocorrect: false,
              decoration: InputDecoration(labelText: copy.externalAiModel),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyController,
              enabled: !busy,
              onChanged: (_) => _dirty = true,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                labelText: copy.externalAiApiKey,
                hintText: copy.externalAiApiKeyHint,
                suffixIcon: IconButton(
                  tooltip: _obscureApiKey
                      ? copy.externalAiShow
                      : copy.externalAiHide,
                  icon: Icon(
                    _obscureApiKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              copy.externalAiApiKeyStorage,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          Text(
            copy.externalAiPrivacy,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            copy.externalAiLimitations,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(copy.save),
          ),
        ],
      ),
    );
  }
}

/// 独立模式未配置服务时统一打开设置，避免进入官方登录流程。
Future<void> openExternalAiSettings(BuildContext context) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => const ExternalAiSettingsScreen()),
  );
}
