import 'dart:async';

import 'package:echo_loop/features/subscription/services/paddle_deep_link_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes only the Paddle success URI', () {
    expect(
      PaddleDeepLinkHandler.isPaddleSuccessUri(
        Uri.parse('echo-loop://paddle-success'),
      ),
      isTrue,
    );
    expect(
      PaddleDeepLinkHandler.isPaddleSuccessUri(
        Uri.parse('echo-loop://paddle-success/'),
      ),
      isTrue,
    );
    expect(
      PaddleDeepLinkHandler.isPaddleSuccessUri(
        Uri.parse('echo-loop://paddle-success/extra'),
      ),
      isFalse,
    );
    expect(
      PaddleDeepLinkHandler.isPaddleSuccessUri(
        Uri.parse('https://echo-loop.top/paddle-success'),
      ),
      isFalse,
    );
    expect(
      PaddleDeepLinkHandler.isPaddleSuccessUri(Uri.parse('echo-loop://other')),
      isFalse,
    );
  });

  test('exposes a route for the unified deep link router', () async {
    var refreshCalls = 0;
    final handler = PaddleDeepLinkHandler(
      refreshEntitlements: () async => refreshCalls++,
    );

    expect(handler.route.name, 'paddle-success');
    expect(
      handler.route.matches(Uri.parse('echo-loop://paddle-success')),
      isTrue,
    );
    expect(handler.route.matches(Uri.parse('echo-loop://other')), isFalse);

    await handler.route.onMatch(Uri.parse('echo-loop://paddle-success'));
    expect(refreshCalls, 1);
  });

  test('coalesces concurrent entitlement refreshes', () async {
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    var refreshCalls = 0;
    final handler = PaddleDeepLinkHandler(
      refreshEntitlements: () {
        refreshCalls++;
        refreshStarted.complete();
        return releaseRefresh.future;
      },
    );

    final first = handler.handleUri(Uri.parse('echo-loop://paddle-success'));
    final second = handler.handleUri(Uri.parse('echo-loop://paddle-success'));
    await refreshStarted.future;

    expect(refreshCalls, 1);
    releaseRefresh.complete();
    await Future.wait([first, second]);
  });

  test('ignores URIs outside the Paddle route', () async {
    var refreshCalls = 0;
    final handler = PaddleDeepLinkHandler(
      refreshEntitlements: () async => refreshCalls++,
    );

    await handler.handleUri(Uri.parse('echo-loop://other'));

    expect(refreshCalls, 0);
  });

  test('a failed refresh does not block a later retry', () async {
    var refreshCalls = 0;
    final handler = PaddleDeepLinkHandler(
      refreshEntitlements: () async {
        refreshCalls++;
        if (refreshCalls == 1) throw StateError('temporary failure');
      },
    );

    await handler.handleUri(Uri.parse('echo-loop://paddle-success'));
    await handler.handleUri(Uri.parse('echo-loop://paddle-success'));

    expect(refreshCalls, 2);
  });
}
