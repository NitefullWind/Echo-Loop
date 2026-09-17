/// 应用级 Deep Link 监听与路由分发。
library;

import 'dart:async';

import 'package:app_links/app_links.dart';

import 'app_logger.dart';

typedef AppDeepLinkMatcher = bool Function(Uri uri);
typedef AppDeepLinkHandler = Future<void> Function(Uri uri);
typedef AppDeepLinkBeforeDispatch = Future<void> Function();

/// 一个业务 Deep Link 路由。
class AppDeepLinkRoute {
  const AppDeepLinkRoute({
    required this.name,
    required this.matches,
    required this.onMatch,
  });

  /// 用于诊断日志的路由名称。
  final String name;

  /// 判断该路由是否负责处理 URI。
  final AppDeepLinkMatcher matches;

  /// URI 命中后执行的业务处理。
  final AppDeepLinkHandler onMatch;
}

/// 应用统一 Deep Link 路由器。
///
/// 该类只负责接收平台 Deep Link 并分发给业务路由，不包含 Paddle、登录或
/// 邀请等具体业务逻辑。每个 URI 只交给第一个匹配的路由处理。
class AppDeepLinkRouter {
  AppDeepLinkRouter({
    required Stream<Uri> uriStream,
    required List<AppDeepLinkRoute> routes,
    AppDeepLinkBeforeDispatch? beforeDispatch,
  }) : _uriStream = uriStream,
       _routes = List.unmodifiable(routes),
       _beforeDispatch = beforeDispatch;

  /// 使用当前平台的 app_links 创建统一路由器。
  factory AppDeepLinkRouter.forCurrentPlatform({
    required List<AppDeepLinkRoute> routes,
    AppDeepLinkBeforeDispatch? beforeDispatch,
  }) {
    final appLinks = AppLinks();
    return AppDeepLinkRouter(
      uriStream: appLinks.uriLinkStream,
      routes: routes,
      beforeDispatch: beforeDispatch,
    );
  }

  final Stream<Uri> _uriStream;
  final List<AppDeepLinkRoute> _routes;
  final AppDeepLinkBeforeDispatch? _beforeDispatch;

  StreamSubscription<Uri>? _uriSubscription;
  Future<void> _dispatchTail = Future<void>.value();
  bool _started = false;
  bool _disposed = false;

  /// 启动冷启动和运行中 Deep Link 监听；重复启动不会注册重复监听。
  ///
  /// [app_links] 的 URI stream 同时包含冷启动 URI 和运行中 URI，因此这里
  /// 只保留一个输入来源，避免同一个冷启动 URI 被处理两次。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    _uriSubscription = _uriStream.listen(
      (uri) => unawaited(_enqueueUri(uri)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.log(
          'AppDeepLink',
          'URI stream error: error=$error stack=$stackTrace',
        );
      },
    );
  }

  /// 将 URI 加入串行分发队列。
  Future<void> _enqueueUri(Uri uri) {
    final dispatch = _dispatchTail.then((_) => handleUri(uri));
    _dispatchTail = dispatch.catchError((error, stackTrace) {
      AppLogger.log(
        'AppDeepLink',
        'URI dispatch failed: error=$error stack=$stackTrace',
      );
    });
    return dispatch;
  }

  /// 将 URI 分发给第一个匹配的业务路由。
  Future<void> handleUri(Uri uri) async {
    if (_disposed) return;

    for (final route in _routes) {
      bool matches;
      try {
        matches = route.matches(uri);
      } catch (error, stackTrace) {
        AppLogger.log(
          'AppDeepLink',
          'Route matcher failed: route=${route.name} '
              'error=$error stack=$stackTrace',
        );
        continue;
      }
      if (!matches) continue;

      AppLogger.log(
        'AppDeepLink',
        'URI matched route: route=${route.name} '
            'scheme=${uri.scheme} host=${uri.host} path=${uri.path}',
      );
      final beforeDispatch = _beforeDispatch;
      if (beforeDispatch != null) {
        try {
          await beforeDispatch();
        } catch (error, stackTrace) {
          AppLogger.log(
            'AppDeepLink',
            'Before-dispatch hook failed: route=${route.name} '
                'error=$error stack=$stackTrace',
          );
        }
      }
      try {
        await route.onMatch(uri);
      } catch (error, stackTrace) {
        AppLogger.log(
          'AppDeepLink',
          'Route handler failed: route=${route.name} '
              'error=$error stack=$stackTrace',
        );
      }
      return;
    }
  }

  /// 释放平台 URI 监听。
  Future<void> dispose() async {
    _disposed = true;
    await _uriSubscription?.cancel();
    _uriSubscription = null;
  }
}
