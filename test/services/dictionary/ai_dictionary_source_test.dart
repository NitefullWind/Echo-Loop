import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:echo_loop/database/daos/sentence_ai_cache_dao.dart';
import 'package:echo_loop/models/dictionary/dictionary_entry.dart';
import 'package:echo_loop/models/dictionary/dictionary_lookup_result.dart';
import 'package:echo_loop/services/dictionary/ai_dictionary_source.dart';
import 'package:echo_loop/services/dictionary/dictionary_source.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockCacheDao extends Mock implements SentenceAiCacheDao {}

class MockApiClient extends Mock implements SentenceAiApiClient {}

DictionaryEntry _entry(String headword) => DictionaryEntry(
  headword: headword,
  pronunciation: const Pronunciation(uk: 'rʌn', us: 'rʌn'),
  meanings: const [],
  commonExpressions: const [],
  wordFamily: const [],
  forms: const [],
  etymology: '',
  learnerTips: const [],
);

MultiWordDictionaryEntry _multiEntry(String headword) =>
    MultiWordDictionaryEntry(
      originalExpression: headword,
      naturalness: '',
      category: '术语',
      pronunciationTips: const [],
      keyPoints: const [],
      meanings: const [
        MultiWordMeaning(translation: ['机器学习'], examples: []),
      ],
      similarExpressions: const [],
      background: '',
    );

/// 中途抛错的流：先发一帧，再抛异常（模拟取消/流内错误，均在写缓存前发生）
Stream<AiDictionaryStreamFrame> _throwingStream(
  AiDictionaryEntry first,
  Object error,
) async* {
  yield AiDictionaryStreamFrame(entry: first, isFinal: false);
  throw error;
}

void main() {
  late MockCacheDao dao;
  late MockApiClient api;
  late AiDictionarySource source;

  setUp(() {
    dao = MockCacheDao();
    api = MockApiClient();
    when(() => api.usesExternalProvider).thenReturn(false);
    source = AiDictionarySource(cacheDao: () => dao, apiClient: () => api);
  });

  /// 默认桩：L2 未命中 + upsert 成功
  void stubCacheMissAndUpsert() {
    when(
      () => dao.getByHash(any(), 'ai_dictionary_v2'),
    ).thenAnswer((_) async => null);
    when(
      () => dao.upsert(any(), 'ai_dictionary_v2', any()),
    ).thenAnswer((_) async {});
  }

  List<AiDictionaryStreamFrame> streamFrames(
    List<AiDictionaryEntry> entries, {
    bool markLastFinal = true,
  }) => [
    for (var i = 0; i < entries.length; i++)
      AiDictionaryStreamFrame(
        entry: entries[i],
        isFinal: markLastFinal && i == entries.length - 1,
      ),
  ];

  void stubWordStream(String word, List<AiDictionaryEntry> frames) {
    when(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream.fromIterable(streamFrames(frames)));
  }

  void stubPhraseStream(String phrase, List<AiDictionaryEntry> frames) {
    when(
      () => api.lookupPhraseStreamFrames(
        phrase,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream.fromIterable(streamFrames(frames)));
  }

  const word = 'run';
  const tokenReq = DictionaryLookupRequest(
    word: word,
    accessToken: 'tok',
    targetLanguage: 'zh-CN',
  );

  test('元数据', () {
    expect(source.id, 'ai');
    expect(source.canBeDisabled, isFalse);
    expect(source.requiresNetwork, isTrue);
  });

  test('缓存未命中且无 accessToken → 抛登录异常', () {
    stubCacheMissAndUpsert();

    expect(
      source.lookup(const DictionaryLookupRequest(word: word)),
      throwsA(isA<DictionaryAuthRequiredException>()),
    );
  });

  test('未登录命中 L1 内存缓存 → 返回缓存结果且不调用 API', () async {
    stubCacheMissAndUpsert();
    stubWordStream(word, [_entry(word)]);

    await source.lookup(tokenReq);
    final result = await source.lookup(
      const DictionaryLookupRequest(word: word, targetLanguage: 'zh-CN'),
    );

    expect((result! as AiDictResult).entry.headword, word);
    verify(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('单词（无空格）路由到 lookupWordStream，返回结果并写 L1+L2', () async {
    stubCacheMissAndUpsert();
    stubWordStream(word, [_entry(word)]);

    final result = await source.lookup(tokenReq);

    expect(result, isA<AiDictResult>());
    expect((result! as AiDictResult).entry.headword, word);
    verify(() => dao.upsert(any(), 'ai_dictionary_v2', any())).called(1);
    verifyNever(
      () => api.lookupPhraseStreamFrames(
        any(),
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('词组（含空格）路由到 lookupPhraseStream', () async {
    stubCacheMissAndUpsert();
    stubPhraseStream('machine learning', [_multiEntry('machine learning')]);

    final result = await source.lookup(
      const DictionaryLookupRequest(
        word: 'machine learning',
        accessToken: 'tok',
        targetLanguage: 'zh-CN',
      ),
    );

    final entry = (result! as AiDictResult).entry;
    expect(entry, isA<MultiWordDictionaryEntry>());
    verify(() => dao.upsert(any(), 'ai_dictionary_v2', any())).called(1);
    verifyNever(
      () => api.lookupWordStreamFrames(
        any(),
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('流式逐帧：lookupStream 每帧 yield AiDictResult，末帧写缓存', () async {
    stubCacheMissAndUpsert();
    // 部分快照 → 完整对象
    stubWordStream(word, [_entry(''), _entry(word)]);

    final results = await source.lookupStream(tokenReq).toList();

    expect(results.length, 2);
    expect((results.last! as AiDictResult).entry.headword, word);
    // 完整完成才写一次缓存（末帧）
    verify(() => dao.upsert(any(), 'ai_dictionary_v2', any())).called(1);
  });

  test('流正常结束但未收到 final → 抛 DictionaryStreamException 且不写缓存', () async {
    stubCacheMissAndUpsert();
    when(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => Stream.fromIterable(
        streamFrames([_entry(''), _entry(word)], markLastFinal: false),
      ),
    );

    await expectLater(
      source.lookupStream(tokenReq).toList(),
      throwsA(isA<DictionaryStreamException>()),
    );
    verifyNever(() => dao.upsert(any(), 'ai_dictionary_v2', any()));
  });

  test('request.word（保留大小写）原样发往后端', () async {
    stubCacheMissAndUpsert();
    stubWordStream('NASA', [_entry('run')]);

    await source.lookup(
      const DictionaryLookupRequest(
        word: 'NASA',
        accessToken: 'tok',
        targetLanguage: 'zh-CN',
      ),
    );

    verify(
      () => api.lookupWordStreamFrames(
        'NASA',
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('缓存 key 按小写复用：NASA 与 nasa 只调一次 API', () async {
    stubCacheMissAndUpsert();
    stubWordStream('NASA', [_entry('NASA')]);

    await source.lookup(
      const DictionaryLookupRequest(
        word: 'NASA',
        accessToken: 'tok',
        targetLanguage: 'zh-CN',
      ),
    );
    // 第二次不同大小写：L1 命中（同缓存键），不再调 API
    await source.lookup(
      const DictionaryLookupRequest(
        word: 'nasa',
        accessToken: 'tok',
        targetLanguage: 'zh-CN',
      ),
    );

    verify(
      () => api.lookupWordStreamFrames(
        'NASA',
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('L1 内存命中 → 第二次即时单帧、不调 API', () async {
    stubCacheMissAndUpsert();
    stubWordStream(word, [_entry(word)]);

    await source.lookup(tokenReq);
    await source.lookup(tokenReq);

    verify(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('clearMemoryCache 后重查再走 L3', () async {
    stubCacheMissAndUpsert();
    stubWordStream(word, [_entry(word)]);

    await source.lookup(tokenReq);
    source.clearMemoryCache();
    await source.lookup(tokenReq);

    verify(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(2);
  });

  test('L2 SQLite 命中 → 即时单帧、不调 API', () async {
    when(
      () => dao.getByHash(any(), 'ai_dictionary_v2'),
    ).thenAnswer((_) async => jsonEncode(_entry(word).toJson()));

    final result = await source.lookup(tokenReq);

    expect((result! as AiDictResult).entry.headword, word);
    verifyNever(
      () => api.lookupWordStreamFrames(
        any(),
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('未登录命中 L2 SQLite 缓存 → 返回缓存结果且不调用 API', () async {
    when(
      () => dao.getByHash(any(), 'ai_dictionary_v2'),
    ).thenAnswer((_) async => jsonEncode(_entry(word).toJson()));

    final result = await source.lookup(
      const DictionaryLookupRequest(word: word, targetLanguage: 'zh-CN'),
    );

    expect((result! as AiDictResult).entry.headword, word);
    verifyNever(
      () => api.lookupWordStreamFrames(
        any(),
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('L2 SQLite 命中多词表达 → MultiWordDictionaryEntry', () async {
    when(() => dao.getByHash(any(), 'ai_dictionary_v2')).thenAnswer(
      (_) async => jsonEncode(_multiEntry('machine learning').toJson()),
    );

    final result = await source.lookup(
      const DictionaryLookupRequest(
        word: 'machine learning',
        accessToken: 'tok',
        targetLanguage: 'zh-CN',
      ),
    );

    expect((result! as AiDictResult).entry, isA<MultiWordDictionaryEntry>());
  });

  test('转发 cancelToken 给 API（流式路径尊重取消）', () async {
    stubCacheMissAndUpsert();
    stubWordStream(word, [_entry(word)]);

    final token = CancelToken();
    await source.lookup(tokenReq, cancelToken: token);

    verify(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: token,
      ),
    ).called(1);
  });

  test('中途取消（流抛 cancel）→ 不写缓存', () async {
    stubCacheMissAndUpsert();
    when(
      () => api.lookupWordStreamFrames(
        word,
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => _throwingStream(
        _entry(''),
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.cancel,
        ),
      ),
    );

    await expectLater(
      source.lookupStream(tokenReq).toList(),
      throwsA(isA<DioException>()),
    );
    // 未完整完成 → 不落缓存
    verifyNever(() => dao.upsert(any(), 'ai_dictionary_v2', any()));
  });

  test('词组过长（API 抛 DictionaryPhraseTooLongException）→ 冒泡且不落缓存', () async {
    stubCacheMissAndUpsert();
    when(
      () => api.lookupPhraseStreamFrames(
        any(),
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(const DictionaryPhraseTooLongException());

    await expectLater(
      source.lookup(
        const DictionaryLookupRequest(
          word: 'a b c d e f g h i',
          accessToken: 'tok',
          targetLanguage: 'zh-CN',
        ),
      ),
      throwsA(isA<DictionaryPhraseTooLongException>()),
    );
    verifyNever(() => dao.upsert(any(), 'ai_dictionary_v2', any()));
  });

  test('其它 DioException 原样冒泡', () async {
    stubCacheMissAndUpsert();
    when(
      () => api.lookupWordStreamFrames(
        any(),
        accessToken: any(named: 'accessToken'),
        targetLanguage: any(named: 'targetLanguage'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
        ),
        type: DioExceptionType.badResponse,
      ),
    );

    await expectLater(source.lookup(tokenReq), throwsA(isA<DioException>()));
  });
}
