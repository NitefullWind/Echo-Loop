import 'dart:async';

import 'package:echo_loop/services/app_deep_link_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatches each stream URI to the first matching route', () async {
    final received = <String>[];
    final links = StreamController<Uri>();
    final router = AppDeepLinkRouter(
      uriStream: links.stream,
      routes: [
        AppDeepLinkRoute(
          name: 'paddle-success',
          matches: (uri) => uri.host == 'paddle-success',
          onMatch: (uri) async => received.add('paddle:${uri.host}'),
        ),
        AppDeepLinkRoute(
          name: 'auth-callback',
          matches: (uri) => uri.host == 'auth',
          onMatch: (uri) async => received.add('auth:${uri.path}'),
        ),
      ],
    );

    await router.start();
    links.add(Uri.parse('echo-loop://auth/callback'));
    await pumpEventQueue();

    expect(received, ['auth:/callback']);
    await router.dispose();
    await links.close();
  });

  test('dispatches runtime URIs and ignores unmatched URIs', () async {
    final links = StreamController<Uri>.broadcast();
    final received = <Uri>[];
    final handled = Completer<void>();
    final route = AppDeepLinkRoute(
      name: 'echo-loop',
      matches: (uri) => uri.scheme == 'echo-loop',
      onMatch: (uri) async {
        received.add(uri);
        handled.complete();
      },
    );
    final runtimeRouter = AppDeepLinkRouter(
      uriStream: links.stream,
      routes: [route],
    );
    await runtimeRouter.start();
    links.add(Uri.parse('https://echo-loop.top/ignored'));
    links.add(Uri.parse('echo-loop://paddle-success'));
    await handled.future;

    expect(received, [Uri.parse('echo-loop://paddle-success')]);
    await runtimeRouter.dispose();
    await links.close();
  });

  test('starts only one subscription and stops after dispose', () async {
    var listenCalls = 0;
    final links = StreamController<Uri>.broadcast(
      onListen: () => listenCalls++,
    );
    var matchCalls = 0;
    final router = AppDeepLinkRouter(
      uriStream: links.stream,
      routes: [
        AppDeepLinkRoute(
          name: 'echo-loop',
          matches: (uri) => uri.scheme == 'echo-loop',
          onMatch: (uri) async => matchCalls++,
        ),
      ],
    );

    await router.start();
    await router.start();
    expect(listenCalls, 1);

    await router.dispose();
    links.add(Uri.parse('echo-loop://paddle-success'));

    expect(matchCalls, 0);
    await links.close();
  });

  test('serializes URI handlers in arrival order', () async {
    final links = StreamController<Uri>.broadcast();
    final firstHandlerStarted = Completer<void>();
    final releaseFirstHandler = Completer<void>();
    final received = <Uri>[];
    final router = AppDeepLinkRouter(
      uriStream: links.stream,
      routes: [
        AppDeepLinkRoute(
          name: 'echo-loop',
          matches: (uri) => uri.scheme == 'echo-loop',
          onMatch: (uri) async {
            received.add(uri);
            if (received.length == 1) {
              firstHandlerStarted.complete();
              await releaseFirstHandler.future;
            }
          },
        ),
      ],
    );

    await router.start();
    final firstUri = Uri.parse('echo-loop://first');
    final secondUri = Uri.parse('echo-loop://second');
    links
      ..add(firstUri)
      ..add(secondUri);
    await firstHandlerStarted.future;
    expect(received, [firstUri]);

    releaseFirstHandler.complete();
    await pumpEventQueue();

    expect(received, [firstUri, secondUri]);
    await router.dispose();
    await links.close();
  });

  test('does not process a URI after disposal', () async {
    final links = StreamController<Uri>.broadcast();
    var matchCalls = 0;
    final router = AppDeepLinkRouter(
      uriStream: links.stream,
      routes: [
        AppDeepLinkRoute(
          name: 'echo-loop',
          matches: (uri) => uri.scheme == 'echo-loop',
          onMatch: (uri) async => matchCalls++,
        ),
      ],
    );

    await router.start();
    await router.dispose();
    links.add(Uri.parse('echo-loop://paddle-success'));
    await pumpEventQueue();

    expect(matchCalls, 0);
    await links.close();
  });
}
