import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:echo_loop/features/subscription/services/paddle_plans_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _PlansDio extends Mock implements Dio {
  _PlansDio(this.data) {
    when(() => get<Map<String, dynamic>>('/api/paddle/plans')).thenAnswer((
      _,
    ) async {
      callCount++;
      return Response<Map<String, dynamic>>(
        data: data,
        statusCode: 200,
        requestOptions: RequestOptions(path: '/api/paddle/plans'),
      );
    });
  }

  final Map<String, dynamic> data;
  int callCount = 0;
}

class _PendingDio extends Mock implements Dio {
  _PendingDio() {
    when(() => get<Map<String, dynamic>>('/api/paddle/plans')).thenAnswer((
      _,
    ) async {
      callCount++;
      if (!requestStarted.isCompleted) requestStarted.complete();
      return Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/api/paddle/plans'),
        statusCode: 200,
        data: await response.future,
      );
    });
  }

  int callCount = 0;
  final response = Completer<Map<String, dynamic>>();
  final requestStarted = Completer<void>();
}

Future<void> _writeCache(
  Directory directory,
  Map<String, dynamic> data, {
  String? contentHash,
  String lastFetchedAt = '2026-09-16T00:00:00.000Z',
  bool includeContentHash = true,
}) async {
  await directory.create(recursive: true);
  final body = jsonEncode(data);
  final hash = contentHash ?? sha256.convert(utf8.encode(body)).toString();
  await File('${directory.path}/plans.json').writeAsString(body);
  final metadata = <String, dynamic>{'lastFetchedAt': lastFetchedAt};
  if (includeContentHash) metadata['contentHash'] = hash;
  await File(
    '${directory.path}/plans.meta.json',
  ).writeAsString(jsonEncode(metadata));
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('paddle_plans_svc_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('persist=false 不写磁盘，内容未变化时仍返回 unchanged', () async {
    final dio = _PlansDio({'plans': []});
    var resolveCount = 0;
    final service = PaddlePlansService(
      dio: dio,
      persist: false,
      resolveDir: () async {
        resolveCount++;
        return tempDir;
      },
    );

    expect(await service.refresh(), isA<PaddlePlansUpdated>());
    expect(await service.refresh(force: true), isA<PaddlePlansUnchanged>());
    expect(dio.callCount, 2);
    expect(resolveCount, 0);
    expect(await tempDir.list().toList(), isEmpty);
  });

  test('unchanged 时 meta 写失败仍更新时间并继续节流', () async {
    final dio = _PlansDio({'plans': []});
    var resolveCount = 0;
    final blocker = File('${tempDir.path}/not_a_directory');
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async {
        resolveCount++;
        if (resolveCount <= 5) return tempDir;
        return Directory(blocker.path);
      },
    );

    expect(await service.refresh(), isA<PaddlePlansUpdated>());
    await blocker.writeAsString('blocker');

    expect(await service.refresh(force: true), isA<PaddlePlansUnchanged>());
    expect(await service.refresh(), isA<PaddlePlansThrottled>());
    expect(dio.callCount, 2);
  });

  test('有效缓存可以单独读取且不会请求网络', () async {
    final data = <String, dynamic>{'plans': [], 'currencyCode': 'CNY'};
    await _writeCache(tempDir, data);
    final dio = _PlansDio({'plans': []});
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async => tempDir,
    );

    expect(await service.loadCachedPlans(), data);
    expect(service.cached, data);
    expect(service.hasInitialized, isTrue);
    expect(dio.callCount, 0);
  });

  test('缓存读取幂等，重复读取不会请求网络或重复访问磁盘', () async {
    await _writeCache(tempDir, {'plans': []});
    final dio = _PlansDio({'plans': []});
    var resolveCount = 0;
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async {
        resolveCount++;
        return tempDir;
      },
    );

    await Future.wait([service.loadCachedPlans(), service.loadCachedPlans()]);
    final firstReadCount = resolveCount;
    await service.loadCachedPlans();

    expect(resolveCount, firstReadCount);
    expect(dio.callCount, 0);
  });

  test('缓存先可读，强制刷新完成后更新内容', () async {
    final cachedData = <String, dynamic>{'plans': [], 'currencyCode': 'CNY'};
    await _writeCache(tempDir, cachedData);
    final updatedData = <String, dynamic>{
      'plans': [
        {'planId': 'plus_monthly', 'priceString': r'$5.99'},
      ],
      'currencyCode': 'USD',
    };
    final dio = _PendingDio();
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async => tempDir,
    );

    expect(await service.loadCachedPlans(), cachedData);
    final refresh = service.refresh(force: true);
    await dio.requestStarted.future;
    expect(service.cached, cachedData);
    expect(dio.callCount, 1);

    dio.response.complete(updatedData);
    await refresh;
    expect(service.cached, updatedData);
  });

  test('缓存 hash 不匹配时丢弃缓存且仍允许普通刷新请求网络', () async {
    await _writeCache(tempDir, {'plans': []}, contentHash: 'invalid-hash');
    final dio = _PlansDio({'plans': []});
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async => tempDir,
    );

    expect(await service.loadCachedPlans(), isNull);
    expect(service.cached, isNull);
    expect(await service.refresh(), isA<PaddlePlansUpdated>());
    expect(dio.callCount, 1);
  });

  test('缓存缺少 hash 时丢弃缓存且仍允许普通刷新请求网络', () async {
    await _writeCache(tempDir, {'plans': []}, includeContentHash: false);
    final dio = _PlansDio({'plans': []});
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async => tempDir,
    );

    expect(await service.loadCachedPlans(), isNull);
    expect(await service.refresh(), isA<PaddlePlansUpdated>());
    expect(dio.callCount, 1);
  });

  test('无缓存时并发加载只完成一次初始化', () async {
    final dio = _PlansDio({'plans': []});
    var resolveCount = 0;
    final service = PaddlePlansService(
      dio: dio,
      resolveDir: () async {
        resolveCount++;
        return tempDir;
      },
    );

    final results = await Future.wait([
      service.loadCachedPlans(),
      service.loadCachedPlans(),
    ]);
    final firstReadCount = resolveCount;
    final third = await service.loadCachedPlans();

    expect(results, [null, null]);
    expect(third, isNull);
    expect(resolveCount, firstReadCount);
    expect(service.hasInitialized, isTrue);
  });

  test('并发强制刷新只产生一个 HTTP 请求', () async {
    final dio = _PendingDio();
    final service = PaddlePlansService(
      dio: dio,
      persist: false,
      resolveDir: () async => tempDir,
    );

    final first = service.refresh(force: true);
    final second = service.refresh(force: true);
    await dio.requestStarted.future;
    expect(dio.callCount, 1);

    dio.response.complete({'plans': []});
    await Future.wait([first, second]);
  });
}
