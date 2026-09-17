/// Paddle Hosted Checkout Deep Link 业务路由。
library;

import '../../../services/app_deep_link_router.dart';
import '../../../services/app_logger.dart';

typedef EntitlementRefresh = Future<void> Function();

/// 处理 Paddle Hosted Checkout 返回 App 的业务路由。
///
/// Deep Link 只表示用户从浏览器回到了 App，不代表支付已经完成；支付状态
/// 必须由后端校验 Paddle Webhook 后，再由 [refreshEntitlements] 回源确认。
class PaddleDeepLinkHandler {
  PaddleDeepLinkHandler({required EntitlementRefresh refreshEntitlements})
    : _refreshEntitlements = refreshEntitlements;

  static const scheme = 'echo-loop';
  static const host = 'paddle-success';

  final EntitlementRefresh _refreshEntitlements;
  Future<void>? _refreshInFlight;

  /// 暴露给统一路由器的 Paddle 业务路由。
  AppDeepLinkRoute get route => AppDeepLinkRoute(
    name: 'paddle-success',
    matches: isPaddleSuccessUri,
    onMatch: handleUri,
  );

  /// 判断 URI 是否是 Echo Loop 的 Paddle 支付回跳。
  static bool isPaddleSuccessUri(Uri uri) {
    return uri.scheme == scheme &&
        uri.host == host &&
        (uri.path.isEmpty || uri.path == '/');
  }

  /// 刷新后端权益；并发回跳复用同一个刷新操作。
  Future<void> handleUri(Uri uri) async {
    if (!isPaddleSuccessUri(uri)) return;

    final existingRefresh = _refreshInFlight;
    if (existingRefresh != null) {
      await existingRefresh;
      return;
    }

    Future<void>? refresh;
    try {
      final operation = _refreshEntitlements();
      refresh = operation;
      _refreshInFlight = operation;
      AppLogger.log(
        'PaddleDeepLink',
        'Paddle return received: scheme=${uri.scheme} host=${uri.host}',
      );
      await operation;
      AppLogger.log('PaddleDeepLink', 'Entitlement refresh completed');
    } catch (error, stackTrace) {
      AppLogger.log(
        'PaddleDeepLink',
        'Entitlement refresh failed: error=$error stack=$stackTrace',
      );
    } finally {
      if (refresh != null && identical(_refreshInFlight, refresh)) {
        _refreshInFlight = null;
      }
    }
  }
}
