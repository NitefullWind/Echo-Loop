import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

import '../features/audio_import/audio_transcode_service.dart';
import '../models/external_speech_config.dart';
import '../models/word_timestamp.dart';
import '../utils/srt_generator.dart';
import 'app_logger.dart';
import 'transcription_api_client.dart';

/// 可安全展示给用户的错误，不附带原始服务响应或请求凭据。
class ExternalSpeechException implements Exception {
  final String message;
  const ExternalSpeechException(this.message);
  @override
  String toString() => message;
}

/// 两家语音服务共用的本地音频转录边界。
abstract interface class ExternalSpeechClient {
  Future<TranscriptResult> transcribe({
    required File audioFile,
    required String language,
    required CancelToken cancelToken,
    void Function(double)? onProgress,
  });
  void dispose();
}

/// 转码由已有音频服务实现，注入点允许协议测试不依赖平台 FFmpeg。
typedef ExternalSpeechTranscode =
    Future<bool> Function({required File source, required File output});

/// 创建仅直连用户配置服务的客户端，不依赖 Echo 登录或上传服务。
ExternalSpeechClient createExternalSpeechClient(ExternalSpeechConfig config) =>
    DirectExternalSpeechClient(config);

/// 服务商协议适配器；资源与单次请求绑定，释放客户端会取消全部请求。
class DirectExternalSpeechClient implements ExternalSpeechClient {
  final ExternalSpeechConfig config;
  final Dio _dio;
  final ExternalSpeechTranscode _transcode;
  final Future<WebSocket> Function(String, Map<String, String>) _connect;
  final Duration chunkInterval;
  final Duration responseTimeout;
  final Set<CancelToken> _active = {};
  bool _disposed = false;

  DirectExternalSpeechClient(
    this.config, {
    Dio? dio,
    ExternalSpeechTranscode? transcode,
    Future<WebSocket> Function(String, Map<String, String>)? connect,
    this.chunkInterval = const Duration(milliseconds: 100),
    this.responseTimeout = const Duration(seconds: 60),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(minutes: 5),
               receiveTimeout: const Duration(minutes: 5),
               followRedirects: false,
             ),
           ),
       _transcode = transcode ?? AudioTranscodeService().transcodeToPcmWav16k,
       _connect = connect ?? _connectSocket;

  static Future<WebSocket> _connectSocket(
    String endpoint,
    Map<String, String> headers,
  ) => WebSocket.connect(endpoint, headers: headers);

  @override
  Future<TranscriptResult> transcribe({
    required File audioFile,
    required String language,
    required CancelToken cancelToken,
    void Function(double)? onProgress,
  }) async {
    if (_disposed) throw const ExternalSpeechException('语音客户端已关闭，请重试');
    if (!config.isConfigured) {
      throw const ExternalSpeechException('请先在设置中填写有效的语音服务配置');
    }
    final token = CancelToken();
    _active.add(token);
    var completed = false;
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!completed) token.cancel();
      }),
    );
    if (cancelToken.isCancelled) token.cancel();
    Directory? temporary;
    Future<bool>? conversion;
    var conversionFinished = false;
    try {
      _throwIfCancelled(token);
      if (!await audioFile.exists() || await audioFile.length() == 0) {
        throw const ExternalSpeechException('音频文件为空或已不存在');
      }
      temporary = await Directory.systemTemp.createTemp('echo-speech-');
      final wav = File('${temporary.path}/audio.wav');
      AppLogger.log('ExternalSpeech', 'start provider=${config.provider.name}');
      onProgress?.call(0);
      final pendingConversion = _transcode(source: audioFile, output: wav)
          .whenComplete(() {
            conversionFinished = true;
          });
      conversion = pendingConversion;
      final converted = await Future.any([
        pendingConversion,
        token.whenCancel.then<bool>((error) => throw error),
      ]).timeout(const Duration(minutes: 5));
      _throwIfCancelled(token);
      if (!converted || !await wav.exists() || await wav.length() <= 44) {
        throw const ExternalSpeechException('音频解码失败或没有有效音频');
      }
      final result = config.provider == ExternalSpeechProvider.aliyun
          ? await _aliyun(wav, language, token, onProgress)
          : await _doubao(wav, language, token, onProgress);
      _throwIfCancelled(token);
      onProgress?.call(1);
      AppLogger.log(
        'ExternalSpeech',
        'completed sentences=${result.sentences.length}',
      );
      return result;
    } on ExternalSpeechException {
      rethrow;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      AppLogger.log(
        'ExternalSpeech',
        'network failure type=${error.type.name} status=${error.response?.statusCode}',
      );
      throw const ExternalSpeechException('语音服务连接失败，请检查网络、凭据和服务额度');
    } catch (_) {
      _throwIfCancelled(token);
      AppLogger.log('ExternalSpeech', 'request failed');
      throw const ExternalSpeechException('语音服务处理失败，请检查网络与服务配置后重试');
    } finally {
      completed = true;
      _active.remove(token);
      final directory = temporary;
      if (directory != null) {
        final pendingConversion = conversion;
        if (!conversionFinished && pendingConversion != null) {
          // FFmpeg 接口不提供本次会话取消；后台完成后再清理，避免删掉仍在写入的文件。
          unawaited(
            pendingConversion.then<void>(
              (_) => _cleanTemporary(directory),
              onError: (Object error) => _cleanTemporary(directory),
            ),
          );
        } else {
          await _cleanTemporary(directory);
        }
      }
    }
  }

  /// HTTP 请求体按块进行 Base64 编码，避免长音频及编码副本同时占用内存。
  Future<TranscriptResult> _doubao(
    File wav,
    String language,
    CancelToken token,
    void Function(double)? progress,
  ) async {
    final length = await wav.length();
    if (length > 100 * 1024 * 1024) {
      throw const ExternalSpeechException('豆包音频文件不能超过 100 MB，请分段转录');
    }
    final headers = <String, Object>{
      if (config.appId.trim().isEmpty) 'X-Api-Key': config.apiKey.trim(),
      if (config.appId.trim().isNotEmpty) ...{
        'X-Api-App-Key': config.appId.trim(),
        'X-Api-Access-Key': config.apiKey.trim(),
      },
      'X-Api-Resource-Id': config.resolvedModel,
      'X-Api-Request-Id': const Uuid().v4(),
      'X-Api-Sequence': '-1',
    };
    const prefix = '{"user":{"uid":"echo-loop"},"audio":{"data":"';
    final suffix =
        '"},"request":${jsonEncode({'model_name': 'bigmodel', 'enable_itn': true, 'enable_punc': true, 'show_utterances': true})}}';
    final contentLength =
        utf8.encode(prefix).length +
        ((length + 2) ~/ 3) * 4 +
        utf8.encode(suffix).length;
    Stream<Uint8List> body() async* {
      yield Uint8List.fromList(utf8.encode(prefix));
      await for (final encoded in base64.encoder.bind(wav.openRead())) {
        _throwIfCancelled(token);
        yield Uint8List.fromList(utf8.encode(encoded));
      }
      yield Uint8List.fromList(utf8.encode(suffix));
    }

    final response = await _dio.post<Object?>(
      config.resolvedEndpoint,
      data: body(),
      options: Options(
        contentType: 'application/json',
        headers: {...headers, 'Content-Length': contentLength},
        followRedirects: false,
      ),
      cancelToken: token,
      onSendProgress: (sent, total) {
        if (!token.isCancelled && total > 0) progress?.call(sent / total * 0.9);
      },
    );
    final status = response.headers.value('X-Api-Status-Code');
    if (status == '20000003') {
      throw const ExternalSpeechException('未识别到语音，请检查音频内容');
    }
    if (status != '20000000') {
      throw const ExternalSpeechException('豆包识别失败，请检查凭据、资源授权与音频格式');
    }
    return parseDoubaoSpeechResult(response.data);
  }

  /// 等待任务启动后按实时速率发送 WAV；只接受本任务的最终句子。
  Future<TranscriptResult> _aliyun(
    File wav,
    String language,
    CancelToken token,
    void Function(double)? progress,
  ) async {
    WebSocket? socket;
    StreamSubscription<Object?>? subscription;
    Timer? timer;
    var finished = false;
    var started = false;
    var sentFinish = false;
    Future<void>? sending;
    final done = Completer<TranscriptResult>();
    final segments = <Map<String, Object?>>[];
    final taskId = const Uuid().v4();
    final length = await wav.length();
    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    void setDeadline(Duration duration) {
      timer?.cancel();
      timer = Timer(
        duration,
        () => fail(const ExternalSpeechException('语音服务响应超时，请重试')),
      );
    }

    final connection =
        _connect(config.resolvedEndpoint, {
          'Authorization': 'Bearer ${config.apiKey.trim()}',
        }).then((value) {
          if (finished || token.isCancelled) {
            unawaited(value.close());
            _throwIfCancelled(token);
            throw const ExternalSpeechException('语音连接已结束');
          }
          return value;
        });
    try {
      socket = await Future.any([
        connection,
        token.whenCancel.then<WebSocket>((error) => throw error),
      ]).timeout(const Duration(seconds: 20));
      final connected = socket;
      unawaited(
        token.whenCancel.then((error) {
          if (!finished) fail(error);
        }),
      );
      Future<void> sendAudio() async {
        try {
          final input = await wav.open();
          try {
            var sent = 0;
            while (sent < length && !done.isCompleted) {
              _throwIfCancelled(token);
              final bytes = await input.read(3200);
              if (bytes.isEmpty) break;
              if (done.isCompleted || finished) break;
              connected.add(bytes);
              sent += bytes.length;
              progress?.call(sent / length * 0.9);
              await Future.any([
                Future<void>.delayed(chunkInterval),
                token.whenCancel.then<void>((error) => throw error),
              ]);
            }
            if (!done.isCompleted) {
              sentFinish = true;
              connected.add(
                jsonEncode({
                  'header': {
                    'action': 'finish-task',
                    'task_id': taskId,
                    'streaming': 'duplex',
                  },
                  'payload': {'input': <String, Object?>{}},
                }),
              );
              setDeadline(responseTimeout);
            }
          } finally {
            await input.close();
          }
        } catch (error) {
          fail(error);
        }
      }

      subscription = connected
          .map<Object?>((event) => event)
          .listen(
            (event) {
              try {
                if (event is! String || done.isCompleted) return;
                final message = _map(jsonDecode(event));
                final header = _map(message['header']);
                if (header['task_id'] != taskId) return;
                switch (header['event']) {
                  case 'task-started':
                    if (!started) {
                      started = true;
                      setDeadline(
                        Duration(milliseconds: (length / 32).ceil()) +
                            responseTimeout,
                      );
                      sending = sendAudio();
                    }
                  case 'result-generated':
                    final sentence = _map(
                      _map(_map(message['payload'])['output'])['sentence'],
                    );
                    if (sentence['sentence_end'] == true &&
                        sentence['heartbeat'] != true) {
                      segments.add(sentence);
                    }
                  case 'task-failed':
                    fail(
                      const ExternalSpeechException(
                        '阿里云识别失败，请检查 API Key、模型权限与服务额度',
                      ),
                    );
                  case 'task-finished':
                    if (!sentFinish) {
                      fail(const ExternalSpeechException('语音服务提前结束，请重试'));
                    } else {
                      done.complete(
                        _parseSegments(segments, startKey: 'begin_time'),
                      );
                    }
                }
              } catch (error) {
                fail(error);
              }
            },
            onError: (Object error) =>
                fail(const ExternalSpeechException('语音连接中断，请重试')),
            onDone: () => fail(const ExternalSpeechException('语音连接提前关闭，请重试')),
          );
      setDeadline(responseTimeout);
      connected.add(
        jsonEncode({
          'header': {
            'action': 'run-task',
            'task_id': taskId,
            'streaming': 'duplex',
          },
          'payload': {
            'task_group': 'audio',
            'task': 'asr',
            'function': 'recognition',
            'model': config.resolvedModel,
            'parameters': {
              'format': 'wav',
              'sample_rate': 16000,
              if (language.isNotEmpty && language != 'auto')
                'language_hints': [language],
              'heartbeat': true,
            },
            'input': <String, Object?>{},
          },
        }),
      );
      return await done.future;
    } finally {
      finished = true;
      timer?.cancel();
      if (!done.isCompleted) fail(const ExternalSpeechException('语音连接已结束'));
      await subscription?.cancel();
      await sending;
      try {
        await socket?.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        AppLogger.log('ExternalSpeech', 'socket close timeout');
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final token in _active) {
      token.cancel();
    }
    _dio.close(force: true);
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  throw const ExternalSpeechException('语音服务返回了无法解析的结果');
}

/// 校验豆包的真实句级时间戳；缺少分句时拒绝伪造整段字幕。
TranscriptResult parseDoubaoSpeechResult(Object? response) {
  final result = _map(_map(response)['result']);
  final utterances = result['utterances'];
  if (utterances is! List<Object?>) {
    throw const ExternalSpeechException('语音服务未返回句子时间戳，请检查接口与模型');
  }
  return _parseSegments(utterances.map(_map).toList(), startKey: 'start_time');
}

/// 将服务商毫秒时间戳归一化；无效的句子拒绝入库，词戳缺失可降级。
TranscriptResult _parseSegments(
  List<Map<String, Object?>> segments, {
  required String startKey,
}) {
  final sentences = <TranscriptSentence>[];
  final words = <WordTimestamp>[];
  var lastStart = -1;
  for (final segment in segments) {
    final text = segment['text'];
    if (text is! String || text.trim().isEmpty) continue;
    final start = segment[startKey];
    final end = segment['end_time'];
    if (start is! int ||
        end is! int ||
        start < 0 ||
        end <= start ||
        start < lastStart) {
      throw const ExternalSpeechException('语音服务返回的句子时间戳无效，请重试');
    }
    lastStart = start;
    final firstWord = words.length;
    final rawWords = segment['words'];
    if (rawWords is List<Object?>) {
      for (final raw in rawWords) {
        if (raw is! Map<String, Object?>) continue;
        final word = raw['text'];
        final wordStart = raw[startKey];
        final wordEnd = raw['end_time'];
        if (word is String &&
            word.trim().isNotEmpty &&
            wordStart is int &&
            wordEnd is int &&
            wordStart >= start &&
            wordEnd > wordStart &&
            wordEnd <= end) {
          words.add(
            WordTimestamp(
              word: word,
              startTime: Duration(milliseconds: wordStart),
              endTime: Duration(milliseconds: wordEnd),
            ),
          );
        }
      }
    }
    final hasWords = firstWord < words.length;
    sentences.add(
      TranscriptSentence(
        text: text.trim(),
        startTime: Duration(milliseconds: start),
        endTime: Duration(milliseconds: end),
        startWordIndex: hasWords ? firstWord : null,
        endWordIndex: hasWords ? words.length - 1 : null,
      ),
    );
  }
  if (sentences.isEmpty) {
    throw const ExternalSpeechException('未识别到有效语音，请检查音频内容');
  }
  return TranscriptResult(
    sentences: sentences,
    words: words.isEmpty ? null : words,
    fullText: sentences.map((sentence) => sentence.text).join(' '),
  );
}

void _throwIfCancelled(CancelToken token) {
  if (token.isCancelled) {
    throw DioException(
      requestOptions: RequestOptions(),
      type: DioExceptionType.cancel,
    );
  }
}

/// 删除本次请求独占的目录；清理失败不覆盖识别或取消结果。
Future<void> _cleanTemporary(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } catch (_) {
    AppLogger.log('ExternalSpeech', 'temporary audio cleanup failed');
  }
}
