# 使用自己的 AI 模型

进入「设置 → 学习 → 外部 AI」，选择服务，填写 API Key 后保存。保存成功后，翻译、句子解析、意群拆分、AI 词典（单词和词组）及 AI 聊天使用所选服务，不要求 Echo Loop 登录或会员，也不消耗 Echo Loop 的试用额度。

| 服务 | Base URL | 预填模型（可修改） |
| --- | --- | --- |
| OpenAI / ChatGPT | `https://api.openai.com/v1` | `gpt-4o-mini` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| 自定义兼容服务 | 服务商提供的地址 | 服务商提供的模型 ID |

自定义服务需要支持 OpenAI Chat Completions 协议。地址可以填 API 根路径或以 `/chat/completions` 结尾的完整路径，自定义路径前缀会保留。建议使用 HTTPS。模型必须在所选服务的账户中可用；本功能不接入 ChatGPT 网页登录，ChatGPT 会员不包含 API 额度。

## 数据与凭据

- 句子、相邻句上下文、查词内容、聊天记录及追问引用会发送给所选服务，费用由该服务按 API 用量收取。
- API Key 保存到当前设备的系统安全存储，不写入普通偏好设置或应用日志。换设备或恢复备份后可能需要重新填写 Key。
- 修改同一服务、同一地址的模型时，Key 留空可保留原值；换服务或地址时必须重新填写 Key。
- 保存失败不会启用新配置。读取失败会显示重试入口并阻止网络请求，不会自动回退 Echo Loop。
- 切换服务或模型后，生成结果按服务和模型隔离缓存；正在进行的聊天会取消并清空，防止把上一服务的会话自动带给新服务。
- 选择 Echo Loop 并保存可恢复原有 AI 服务及登录/会员规则，同时删除当前外部 Key。系统安全存储清理失败会记录不含凭据的诊断日志。

## 支持范围与错误处理

云端音频转录继续使用 Echo Loop。外部模式不支持复述音频评估，需要切回 Echo Loop 后使用。

解析、词典、意群需要模型返回有效的结构化 JSON。服务明确拒绝 `response_format` 参数时，会去掉该参数重试一次；其它请求错误不会自动重复重试。空结果、无效结构和不完整的聊天流会报错，不作为成功结果缓存。

外部服务返回鉴权失败时检查 Key；余额不足时检查服务商账户；限流时稍后重试；地址或模型错误时核对 Base URL 和模型 ID。外部错误不会引导购买 Echo Loop 会员。

## 手动验证

1. 保存配置后重新打开设置页，确认服务、地址和模型保持；Key 输入框为空是正常的，不会回显已保存的 Key。
2. 在未登录 Echo Loop 的情况下打开一句未生成过结果的英语句子，依次使用翻译、解析、意群、AI 查词及聊天。
3. 检查服务商控制台的 API 用量，确认请求来自所填模型。请求会产生服务商费用。
4. 在聊天生成中切换模型，确认旧会话被清空、新问题使用新模型；重新进入讲解页时旧模型的结果不混用。
5. 填入无效 Key 后请求，确认显示服务商错误；切回 Echo Loop 后确认原有登录/会员行为恢复。

开发验证使用注入 HTTP transport 的单元测试和真实页面 widget 测试，不需要真实 API Key。真实服务连通性、系统安全存储及音频功能仍需在目标设备上验证。

协议参考：[OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)。为兼容 DeepSeek 和其它服务，结构化请求使用 `json_object` 并在客户端校验业务结果。

## 本次开发验证（2026-09-18）

- Flutter 3.41.5 / Dart 3.11.3；46 个改动相关 Dart 文件静态分析通过，`git diff --check HEAD` 通过。
- 23 个相关测试文件：440 项通过，5 项沿用原有跳过条件。覆盖配置持久化与失败恢复、真实 Dio transport、结构化响应、SSE、缓存隔离、聊天取消、词典切换及学习/设置页面回归。
- 额外执行收藏播放和视频播放器的两个测试文件：26 项通过、27 项失败。在未修改的 `2c396c5a` 独立检出中重跑，失败用例名单完全一致，包含 Windows 路径分隔符、文件占用及原有媒体测试夹具问题。没有为此次接入修改播放业务或跳过这些测试。
- `scripts/check.sh` 此前已尝试，但 WSL 环境找不到 Flutter；脚本还包含 macOS 集成测试和构建，不适用于当前 Windows 环境。本次使用 Windows Flutter 执行上述相关检查。
- 当前没有对应的 AI 集成测试套件；通过注入 HTTP transport 和真实 widget 验证边界。没有调用真实付费 API；目标设备上的系统安全存储和端到端联调仍需按上面的步骤验证。后续已通过个人 fork 的 GitHub Actions 生成 Android 安装包，见[自动打包说明](fork-android-build.md)。

在当前 Windows 开发环境中，可先运行这些关键测试：

```powershell
& E:/flutter-sdk/flutter/bin/flutter.bat test --no-pub test/providers/external_ai_storage_test.dart test/providers/external_ai_learning_test.dart test/services/external_ai_transport_test.dart test/screens/external_ai_settings_screen_test.dart
```

安装包或真机调试沿用仓库 README 的环境配置；连接 Android 设备后运行 `flutter run -d <DEVICE_ID> --dart-define-from-file=.dev.env`。Windows 构建插件需要系统开启开发者模式以支持符号链接。

## 改动文件

- `TASKS.md`
- `docs/external-ai.md`
- `lib/features/chatbot/providers/chat_api_client_provider.dart`
- `lib/features/chatbot/providers/chat_session_controller.dart`
- `lib/features/chatbot/services/chat_api_client.dart`
- `lib/features/chatbot/widgets/chat_view.dart`
- `lib/features/chatbot/widgets/sentence_chat_button.dart`
- `lib/l10n/app_en.arb`
- `lib/l10n/app_localizations.dart`
- `lib/l10n/app_localizations_en.dart`
- `lib/l10n/app_localizations_zh.dart`
- `lib/l10n/app_zh.arb`
- `lib/models/external_ai_config.dart`
- `lib/models/external_ai_settings.dart`
- `lib/providers/dictionary/lookup_controller.dart`
- `lib/providers/external_ai_settings_provider.dart`
- `lib/providers/sentence_ai_provider.dart`
- `lib/screens/external_ai_settings_screen.dart`
- `lib/screens/settings_screen.dart`
- `lib/services/dictionary/ai_dictionary_source.dart`
- `lib/services/external_ai_prompts.dart`
- `lib/services/external_ai_settings_store.dart`
- `lib/services/openai_compatible_ai_client.dart`
- `lib/services/sentence_ai_api_client.dart`
- `lib/widgets/practice/sentence_explanation_view.dart`
- `test/features/chatbot/providers/chat_session_controller_test.dart`
- `test/features/chatbot/widgets/chat_view_test.dart`
- `test/features/chatbot/widgets/sentence_chat_button_test.dart`
- `test/helpers/external_ai_adapter.dart`
- `test/providers/dictionary/lookup_controller_test.dart`
- `test/providers/external_ai_learning_test.dart`
- `test/providers/external_ai_settings_provider_test.dart`
- `test/providers/external_ai_storage_test.dart`
- `test/providers/sentence_ai_provider_test.dart`
- `test/screens/external_ai_settings_screen_test.dart`
- `test/screens/favorites_prewarm_test.dart`
- `test/screens/favorites_screen_test.dart`
- `test/screens/intensive_listen_player_screen_test.dart`
- `test/screens/listen_and_repeat_player_screen_test.dart`
- `test/screens/media_playback_screen_test.dart`
- `test/screens/player_screen_test.dart`
- `test/screens/retell_player_screen_test.dart`
- `test/screens/review_difficult_practice_screen_test.dart`
- `test/screens/sentence_detail_screen_test.dart`
- `test/screens/settings_screen_test.dart`
- `test/services/dictionary/ai_dictionary_source_test.dart`
- `test/services/external_ai_transport_test.dart`
- `test/services/openai_compatible_ai_client_test.dart`
- `test/services/sentence_ai_external_test.dart`
- `test/widgets/sentence_explanation_view_auth_test.dart`
