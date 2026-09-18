/// 反爬 / 人机验证挑战页检测
///
/// 部分播客托管（如 SiteGround 的 sgcaptcha、Cloudflare）在判定请求为机器人时，
/// 不返回 RSS，而是返回一个需要执行 JS proof-of-work 的 HTML 验证页。Dio 没有
/// JS 引擎，无法通过挑战，拿到的就是这张验证页 —— 解析时只会看到 `<html>`、缺少
/// `<channel>`，从而误报「格式不支持」。
///
/// 这里在数据入口识别这类响应，以便给出准确提示（「该源启用了反爬保护」）而非
/// 误导性的解析失败。
library;

/// 已知反爬/验证页的正文特征关键字（小写匹配）。
const _challengeMarkers = <String>[
  'sgcaptcha', // SiteGround
  'sgchallenge', // SiteGround proof-of-work 变量名
  'robot challenge', // SiteGround 验证页标题
  'cf-browser-verification', // Cloudflare
  'cf_chl_', // Cloudflare challenge token
  'just a moment', // Cloudflare 等待页标题
  'attention required', // Cloudflare 拦截页标题
  'enable javascript and cookies', // 通用 JS 挑战提示
];

/// 判断 [body] 是否为反爬/人机验证挑战页而非真正的 RSS/Atom feed。
///
/// 有 feed 根元素的响应优先视为合法 feed：节目正文可能自然出现反爬关键词。
/// 其余响应命中已知特征关键字，或「看起来是 HTML 文档但不含任何 feed 根元素」
/// 时判定为挑战页。[contentType] 取自响应头，用于辅助判断是否为 HTML。
bool isAntiBotChallenge({String? contentType, required String body}) {
  final lower = body.toLowerCase();
  final hasFeedRoot =
      lower.contains('<rss') ||
      lower.contains('<feed') ||
      lower.contains('<channel');
  if (hasFeedRoot) return false;

  if (_challengeMarkers.any(lower.contains)) return true;

  final trimmed = lower.trimLeft();
  final looksHtml =
      (contentType?.toLowerCase().contains('text/html') ?? false) ||
      trimmed.startsWith('<!doctype html') ||
      trimmed.startsWith('<html');
  return looksHtml;
}
