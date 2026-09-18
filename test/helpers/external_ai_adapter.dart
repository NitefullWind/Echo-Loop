import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 使用真实 Dio 请求管线，替换 HTTP 传输，验证地址、凭据和协议而无需付费请求。
class ExternalAiTestAdapter implements HttpClientAdapter {
  ExternalAiTestAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) => closed = true;
}

ResponseBody externalJson(Object? value, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

ResponseBody externalCompletion(Object? value) => externalJson({
  'choices': [
    {
      'message': {'content': jsonEncode(value)},
      'finish_reason': 'stop',
    },
  ],
});
