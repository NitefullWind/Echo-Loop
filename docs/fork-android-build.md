# 个人 fork 自动打包

仓库：https://github.com/NitefullWind/Echo-Loop

开发分支：`external-ai`。修改代码并 push 到该分支会运行 **Build personal Android APK**；也可在 GitHub Actions 页面手动选择 **Run workflow**。仅修改 Markdown 文档不会重复打包。

## 构建方案

复用 Flutter 3.41.5 和项目的 `dev` flavor，执行静态分析及文本 AI 回归测试后生成 release 模式的 ARM64 APK。个人流程独立于上游的商店发布流程，不需要作者的 App Store、Google Play、Cloudflare 或 Echo Loop 后端凭据。

安装后名称为 **Echo Loop Dev**，包名 `app.echoloop.dev`，可与官方版共存。数据分开保存；已有学习资料可通过应用的备份/导入功能迁移。该包适用于 Android 7.0 及以上的 ARM64 设备。

首次安装后，进入「设置 → 学习 → 外部 AI」配置 OpenAI、DeepSeek 或自定义服务。模型 Key 不写入代码、GitHub Secret 或 APK。此构建没有配置 Echo Loop 登录后端，因此官方登录、会员及云转录等后端功能不可用；本地学习和外部文本 AI 可用。

## 固定签名

GitHub 仓库 Secret `FORK_ANDROID_KEYSTORE_BASE64` 保存个人签名文件。每次构建恢复同一证书，后续 APK 可以覆盖升级并保留数据。不要删除或重新生成这个 Secret。

签名沿用 Android dev 配置的别名 `androiddebugkey`，keystore/key 密码均为 `android`。密码是格式约定，私钥本体仍必须保密；不能将 Base64、keystore 或本地环境文件提交到仓库。

本机备份位于 `E:\Code\echo-loop-signing\debug.keystore`，不在 Git 工作区。丢失本机备份不会影响现有 Actions 构建，但 GitHub Secret 不能明文下载，建议自行备份这个文件。

## 下载

1. 打开仓库的 **Actions → Build personal Android APK**。
2. 选择最新成功记录，在 **Artifacts** 下载 `Echo-Loop-External-AI-arm64-<构建号>`。
3. 解压 ZIP，安装 APK；同目录的 `SHA256SUMS.txt` 可校验文件完整性。

Artifact 保留 30 天，下载时需要登录 GitHub。过期后可以重新运行 workflow；运行编号作为 Android versionCode，后续新运行自动递增。该流程不会上传应用商店或自动发布上游版本。
