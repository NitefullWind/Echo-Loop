import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';

/// 提供应用窗口的跨桌面平台激活能力。
abstract interface class AppWindowActivator {
  /// 初始化桌面窗口控制插件。
  Future<void> initialize();

  /// 恢复、显示并聚焦应用主窗口。
  Future<void> activate();
}

/// 使用 [window_manager] 激活桌面应用窗口。
class WindowManagerAppWindowActivator implements AppWindowActivator {
  bool _initialized = false;

  bool get _isDesktop {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.iOS => false,
    };
  }

  @override
  Future<void> initialize() async {
    if (!_isDesktop || _initialized) return;
    try {
      await windowManager.ensureInitialized();
      _initialized = true;
    } catch (error, stackTrace) {
      AppLogger.log(
        'AppWindow',
        'Window manager initialization failed: error=$error '
            'stack=$stackTrace',
      );
    }
  }

  @override
  Future<void> activate() async {
    if (!_isDesktop) return;
    await initialize();
    if (!_initialized) return;

    await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }
}
