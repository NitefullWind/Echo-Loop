import 'package:echo_loop/config/external_services_config.dart';
import 'package:echo_loop/features/auth/providers/auth_providers.dart';
import 'package:echo_loop/features/subscription/providers/subscription_availability.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/package_info_provider.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/screens/settings_screen.dart';
import 'package:echo_loop/screens/external_speech_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/mock_providers.dart';
import '../helpers/test_app.dart';

void main() {
  testWidgets('独立版隐藏账号和订阅，外部语音入口可打开配置页', (tester) async {
    if (!externalServicesOnly) return;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      createTestScreen(
        const SettingsScreen(),
        overrides: [
          ...learningSettingsOverrides(prefs: prefs),
          packageInfoProvider.overrideWithValue(
            PackageInfo(
              appName: 'Echo Loop',
              packageName: 'test.personal',
              version: '1.0.0',
              buildNumber: '1',
            ),
          ),
          showOfflineAsrSectionProvider.overrideWithValue(false),
          supabaseSessionProvider.overrideWith(
            (ref) => throw StateError('独立版不应读取账号'),
          ),
          subscriptionAvailabilityProvider.overrideWith(
            (ref) => throw StateError('独立版不应读取订阅'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final copy = lookupAppLocalizations(const Locale('en'));
    expect(find.text(copy.account), findsNothing);
    expect(find.text(copy.premiumEntryTitle), findsNothing);
    final entry = find.text('外部语音服务');
    await tester.scrollUntilVisible(entry, 300);
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(ExternalSpeechSettingsScreen), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
