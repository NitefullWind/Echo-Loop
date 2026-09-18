import 'package:echo_loop/config/external_services_config.dart';
import 'package:echo_loop/features/subscription/services/revenuecat_purchase_service.dart';
import 'package:echo_loop/models/app_update_info.dart';
import 'package:echo_loop/providers/app_update_provider.dart';
import 'package:echo_loop/providers/package_info_provider.dart';
import 'package:echo_loop/providers/startup_bootstrap_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('独立版后台和手动更新均不创建官方SDK或商店依赖', () async {
    if (!externalServicesOnly) return;
    final container = ProviderContainer(
      overrides: [
        packageInfoProvider.overrideWith(
          (ref) => throw StateError('不应读取官方更新包信息'),
        ),
        purchaseServiceProvider.overrideWith(
          (ref) => throw StateError('不应创建商店服务'),
        ),
        thirdPartyStartupProvider.overrideWith(
          (ref) => throw StateError('不应触发第三方SDK启动'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(appUpdateProvider.notifier);
    expect(container.read(appUpdateProvider), isA<AppUpdateInitial>());
    await controller.checkInBackground();
    final result = await controller.manualCheck();
    expect(result.type, AppUpdateType.none);
    expect(container.read(appUpdateProvider), isA<AppUpdateInitial>());
  });
}
