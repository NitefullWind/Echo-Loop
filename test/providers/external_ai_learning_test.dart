import 'dart:convert';

import 'package:echo_loop/database/daos/sentence_ai_cache_dao.dart';
import 'package:echo_loop/models/dictionary/dictionary_entry.dart';
import 'package:echo_loop/models/dictionary/dictionary_lookup_result.dart';
import 'package:echo_loop/models/external_ai_config.dart';
import 'package:echo_loop/providers/sentence_ai_provider.dart';
import 'package:echo_loop/services/dictionary/ai_dictionary_source.dart';
import 'package:echo_loop/services/dictionary/dictionary_source.dart';
import 'package:echo_loop/services/openai_compatible_ai_client.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/external_ai_adapter.dart';

class _Dao extends Mock implements SentenceAiCacheDao {}

void main() {
  late _Dao dao;
  late Map<(String, String), String> cache;
  setUp(() {
    dao = _Dao();
    cache = {};
    when(() => dao.getByHash(any(), any())).thenAnswer((call) async {
      final hash = call.positionalArguments[0];
      final type = call.positionalArguments[1];
      return hash is String && type is String ? cache[(hash, type)] : null;
    });
    when(() => dao.upsert(any(), any(), any())).thenAnswer((call) async {
      final hash = call.positionalArguments[0];
      final type = call.positionalArguments[1];
      final data = call.positionalArguments[2];
      if (hash is String && type is String && data is String) {
        cache[(hash, type)] = data;
      }
    });
  });

  SentenceAiApiClient makeClient(
    ExternalAiTestAdapter adapter, {
    String model = 'model',
  }) {
    final client = SentenceAiApiClient.withExternalClient(
      OpenAiCompatibleAiClient(
        ExternalAiConfig(
          providerLabel: 'Custom',
          baseUrl: 'https://example.com/v1',
          model: model,
          apiKey: 'key',
        ),
        adapter: adapter,
      ),
    );
    addTearDown(client.dispose);
    return client;
  }

  SentenceAiNotifier makeNotifier(SentenceAiApiClient client) {
    final notifier = SentenceAiNotifier(
      cacheDao: dao,
      apiClient: client,
      guardFeature: (_) =>
          fail('External request must not use Echo Loop quota'),
      onConsumeTrial: (_) => fail('External request must not consume trial'),
      beforeApiRequest: (_, {required respectLocalQuotaReset}) async =>
          fail('Internal quota check'),
      onApiSucceeded: (_) async => fail('Internal success callback'),
      onBackendQuotaRejected: (_) => fail('Internal entitlements refresh'),
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  test('未登录翻译、解析、意群全链路成功，跳过全部内部额度回调并缓存完整结果', () async {
    final adapter = ExternalAiTestAdapter((request) async {
      final data = request.data;
      final prompt = data is Map ? data['messages'].toString() : '';
      if (prompt.contains('sense groups')) {
        return externalCompletion({
          'medium': ['Hello world.'],
          'fine': ['Hello ', 'world.'],
        });
      }
      if (prompt.contains('analyze')) {
        return externalCompletion({
          'grammar': [
            {'point': 'greeting', 'note': '问候语'},
          ],
          'vocabulary': [
            {'term': 'world', 'note': '世界'},
          ],
          'listening': [],
        });
      }
      return externalCompletion({'translation': '你好，世界。'});
    });
    final notifier = makeNotifier(makeClient(adapter));
    final translation = await notifier
        .getTranslationStream(
          'Hello world.',
          targetLanguage: 'zh-CN',
          respectLocalQuotaReset: true,
        )
        .last;
    expect(translation.translation, '你好，世界。');
    expect(
      (await notifier
              .getAnalysisStream(
                'Hello world.',
                targetLanguage: 'zh-CN',
                respectLocalQuotaReset: true,
              )
              .last)
          .grammar
          .single
          .note,
      '问候语',
    );
    expect(
      (await notifier
              .getSenseGroupsStream(
                'Hello world.',
                respectLocalQuotaReset: true,
              )
              .last)
          .fine,
      ['Hello ', 'world.'],
    );
    expect(cache.length, 3);
    await notifier
        .getTranslationStream('Hello world.', targetLanguage: 'zh-CN')
        .last;
    expect(adapter.requests.length, 3);
  });

  test('切换模型隔离 L2 缓存，切回原模型可读缓存', () async {
    final adapter = ExternalAiTestAdapter(
      (_) async => externalCompletion({'translation': '你好'}),
    );
    final first = makeClient(adapter);
    await makeNotifier(
      first,
    ).getTranslationStream('Hello', targetLanguage: 'zh-CN').last;
    await makeNotifier(
      makeClient(adapter, model: 'another-model'),
    ).getTranslationStream('Hello', targetLanguage: 'zh-CN').last;
    expect(adapter.requests.length, 2);
    final restored = makeNotifier(first);
    expect(
      await restored.preloadTranslationFromDb('Hello', targetLanguage: 'zh-CN'),
      true,
    );
    expect(
      restored
          .getCachedTranslation('Hello', targetLanguage: 'zh-CN')
          ?.translation,
      '你好',
    );
    expect(adapter.requests.length, 2);
  });

  test('未登录词典能够读取单词和词组，嵌套字段可由现有模型展示', () async {
    final adapter = ExternalAiTestAdapter((request) async {
      final data = request.data;
      final prompt = data is Map ? data['messages'].toString() : '';
      if (prompt.contains('originalExpression')) {
        return externalCompletion({
          'originalExpression': 'give up',
          'category': '短语动词',
          'meanings': [
            {
              'translation': ['放弃'],
              'examples': [],
            },
          ],
          'keyPoints': [
            {
              'point': '可分离',
              'sentence': 'Never give up.',
              'translation': '永不放弃。',
            },
          ],
        });
      }
      return externalCompletion({
        'headword': 'hello',
        'pronunciation': {'uk': 'həˈləʊ', 'us': 'həˈloʊ'},
        'meanings': [
          {
            'partOfSpeech': 'int.',
            'translation': ['你好'],
            'definition': 'A greeting.',
            'examples': [
              {'sentence': 'Hello!', 'translation': '你好！'},
            ],
          },
        ],
      });
    });
    final client = makeClient(adapter);
    final source = AiDictionarySource(
      cacheDao: () => dao,
      apiClient: () => client,
    );
    final word = await source.lookup(
      const DictionaryLookupRequest(word: 'hello'),
    );
    expect(word, isA<AiDictResult>());
    final phrase = await source.lookup(
      const DictionaryLookupRequest(word: 'give up'),
    );
    expect(phrase, isA<AiDictResult>());
    final entries = cache.values
        .map(jsonDecode)
        .whereType<Map<String, Object?>>()
        .toList();
    final entry = DictionaryEntry.fromJson(entries.first);
    expect(entry.meanings.single.examples.single.translation, '你好！');
    final expression = MultiWordDictionaryEntry.fromJson(entries.last);
    expect(expression.keyPoints.single.point, '可分离');
    expect(adapter.requests.length, 2);
  });

  test('空翻译和不匹配意群不能写缓存', () async {
    final adapter = ExternalAiTestAdapter(
      (_) async => externalCompletion({
        'translation': '',
        'medium': ['wrong'],
        'fine': ['wrong'],
      }),
    );
    final notifier = makeNotifier(makeClient(adapter));
    await expectLater(
      notifier.getTranslationStream('Hello', targetLanguage: 'zh-CN').last,
      throwsA(isA<ExternalAiResponseException>()),
    );
    await expectLater(
      notifier.getSenseGroupsStream('Hello').last,
      throwsA(isA<ExternalAiResponseException>()),
    );
    expect(cache, isEmpty);
  });
}
