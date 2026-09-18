import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';
import 'package:echo_loop/models/external_speech_config.dart';
import 'package:echo_loop/services/external_speech_client.dart';

class _Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?)
  handle;
  _Adapter(this.handle);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handle(options, requestStream);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late File source;
  final audio = List<int>.generate(6401, (i) => i % 256);
  Future<bool> transcode({required File source, required File output}) async {
    await output.writeAsBytes(audio);
    return true;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('speech-test-');
    source = await File('${directory.path}/input.wav').writeAsBytes(audio);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  final result = {
    'result': {
      'utterances': [
        {
          'text': 'Hello',
          'start_time': 10,
          'end_time': 500,
          'words': [
            {'text': 'Hello', 'start_time': 10, 'end_time': 500},
          ],
        },
      ],
    },
  };

  for (final appId in ['', 'legacy-app']) {
    test('豆包 ${appId.isEmpty ? '新' : '旧'}认证和流式音频保持一致', () async {
      final dio = Dio();
      dio.httpClientAdapter = _Adapter((options, stream) async {
        expect(options.headers['X-Api-Resource-Id'], 'volc.bigasr.auc_turbo');
        expect(options.headers['X-Api-Sequence'], '-1');
        expect(
          options.headers[appId.isEmpty ? 'X-Api-Key' : 'X-Api-Access-Key'],
          'secret',
        );
        expect(options.headers['X-Api-App-Key'], appId.isEmpty ? null : appId);
        final bytes = <int>[];
        if (stream != null) {
          await for (final chunk in stream) {
            bytes.addAll(chunk);
          }
        }
        expect(bytes.length, options.headers['Content-Length']);
        final Object? body = jsonDecode(utf8.decode(bytes));
        if (body case {
          'audio': {'data': final String data},
          'request': {'show_utterances': true},
        }) {
          expect(base64Decode(data), audio);
        } else {
          fail('缺少音频或句子请求');
        }
        return ResponseBody.fromString(
          jsonEncode(result),
          200,
          headers: {
            'content-type': ['application/json'],
            'x-api-status-code': ['20000000'],
          },
        );
      });
      final client = DirectExternalSpeechClient(
        ExternalSpeechConfig(
          provider: ExternalSpeechProvider.doubao,
          apiKey: 'secret',
          appId: appId,
        ),
        dio: dio,
        transcode: transcode,
      );
      addTearDown(client.dispose);
      final transcript = await client.transcribe(
        audioFile: source,
        language: 'en',
        cancelToken: CancelToken(),
      );
      expect(transcript.sentences.single.startTime.inMilliseconds, 10);
      expect(transcript.words?.single.word, 'Hello');
    });
  }

  test('豆包 HTTP 成功但服务失败不泄露原始响应', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((_, stream) async {
        if (stream != null) await stream.drain<void>();
        return ResponseBody.fromString(
          '{"secret":"credential"}',
          200,
          headers: {
            'content-type': ['application/json'],
            'x-api-status-code': ['45000001'],
          },
        );
      });
    final client = DirectExternalSpeechClient(
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.doubao,
        apiKey: 'secret',
      ),
      dio: dio,
      transcode: transcode,
    );
    addTearDown(client.dispose);
    await expectLater(
      client.transcribe(
        audioFile: source,
        language: 'en',
        cancelToken: CancelToken(),
      ),
      throwsA(
        isA<ExternalSpeechException>().having(
          (e) => e.message,
          'safe error',
          isNot(contains('credential')),
        ),
      ),
    );
  });

  test('转码中取消立即结束，转码完成后删除临时文件', () async {
    final entered = Completer<File>();
    final complete = Completer<bool>();
    final client = DirectExternalSpeechClient(
      const ExternalSpeechConfig(
        provider: ExternalSpeechProvider.aliyun,
        apiKey: 'secret',
      ),
      transcode: ({required source, required output}) {
        entered.complete(output);
        return complete.future;
      },
    );
    addTearDown(client.dispose);
    final token = CancelToken();
    final future = client.transcribe(
      audioFile: source,
      language: 'en',
      cancelToken: token,
    );
    final output = await entered.future;
    final check = expectLater(
      future,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    token.cancel();
    await check;
    expect(await output.parent.exists(), isTrue);
    await output.writeAsBytes(audio);
    complete.complete(true);
    // 等待实际文件删除事件，不用任意延时掩盖竞态。
    for (var i = 0; i < 100 && await output.parent.exists(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(await output.parent.exists(), isFalse);
  });

  test('无效时间戳拒绝产生伪造字幕', () {
    expect(
      () => parseDoubaoSpeechResult({
        'result': {
          'utterances': [
            {'text': 'bad', 'start_time': 500, 'end_time': 10},
          ],
        },
      }),
      throwsA(isA<ExternalSpeechException>()),
    );
    expect(
      () => parseDoubaoSpeechResult({
        'result': {'text': 'without timestamps'},
      }),
      throwsA(isA<ExternalSpeechException>()),
    );
  });

  for (final mode in ['success', 'close', 'timeout']) {
    test('阿里 WebSocket $mode', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final actions = <String>[];
      final received = <int>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((Object? event) {
          if (event is List<int>) {
            received.addAll(event);
            return;
          }
          if (event is! String) return;
          final Object? decoded = jsonDecode(event);
          if (decoded case {
            'header': {
              'action': final String action,
              'task_id': final String task,
            },
          }) {
            actions.add(action);
            void send(
              String event, [
              Map<String, Object?> payload = const {},
            ]) => socket.add(
              jsonEncode({
                'header': {'task_id': task, 'event': event},
                'payload': payload,
              }),
            );
            if (action == 'run-task') {
              expect(received, isEmpty);
              if (mode == 'close') {
                unawaited(socket.close());
                return;
              }
              if (mode == 'timeout') return;
              send('task-started');
            } else if (action == 'finish-task') {
              send('result-generated', {
                'output': {
                  'sentence': {
                    'text': 'Hello',
                    'begin_time': 10,
                    'end_time': 500,
                    'sentence_end': true,
                  },
                },
              });
              send('task-finished');
            }
          }
        });
      });
      final client = DirectExternalSpeechClient(
        const ExternalSpeechConfig(
          provider: ExternalSpeechProvider.aliyun,
          apiKey: 'secret',
        ),
        transcode: transcode,
        connect: (_, headers) {
          expect(headers['Authorization'], 'Bearer secret');
          return WebSocket.connect('ws://127.0.0.1:${server.port}');
        },
        chunkInterval: Duration.zero,
        responseTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.dispose);
      final future = client.transcribe(
        audioFile: source,
        language: 'en',
        cancelToken: CancelToken(),
      );
      if (mode == 'success') {
        expect((await future).fullText, 'Hello');
        expect(actions, ['run-task', 'finish-task']);
        expect(received, audio);
      } else {
        await expectLater(future, throwsA(isA<ExternalSpeechException>()));
      }
    });
  }
}
