import 'package:echo_loop/features/auth/providers/auth_providers.dart';
import 'package:echo_loop/features/official_collections/providers/discover_podcasts_provider.dart';
import 'package:echo_loop/features/podcast/podcast_models.dart';
import 'package:echo_loop/features/podcast/podcast_preview_provider.dart';
import 'package:echo_loop/features/podcast/podcast_repository.dart';
import 'package:echo_loop/features/podcast/podcast_search_provider.dart';
import 'package:echo_loop/features/podcast/podcast_search_service.dart';
import 'package:echo_loop/features/podcast/screens/podcast_discovery_screen.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/models/collection.dart';
import 'package:echo_loop/providers/collection_provider.dart';
import 'package:echo_loop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../helpers/mock_providers.dart';
import '../../helpers/test_app.dart';
import '../official_collections/fixtures/catalog_fixtures.dart';

/// 搜索服务替身：返回预置结果，记录调用词。
class _FakeSearchService extends PodcastSearchService {
  _FakeSearchService(this.results);
  final List<PodcastSearchResult> results;
  String? lastTerm;

  @override
  Future<List<PodcastSearchResult>> search(
    String term, {
    int limit = 25,
  }) async {
    lastTerm = term;
    return results;
  }
}

/// Podcast 仓库替身：记录订阅输入 URL，返回一个 podcast 合集。
class _FakePodcastRepository extends Fake implements PodcastRepository {
  final List<String> subscribed = [];
  final List<String?> knownFeedUrls = [];

  @override
  Future<Collection> createAndFetch(
    String inputUrl, {
    String? knownFeedUrl,
  }) async {
    subscribed.add(inputUrl);
    knownFeedUrls.add(knownFeedUrl);
    return Collection(
      id: 'c-$inputUrl',
      name: 'Subscribed',
      createdDate: DateTime(2026, 1, 1),
      source: CollectionSource.podcast,
      podcastInputUrl: inputUrl,
      podcastFeedUrl: knownFeedUrl ?? inputUrl,
    );
  }
}

/// 预置一个已订阅 podcast 合集（feedUrl 用于「去学习」判定）。
TestCollectionList Function() _seeded(String feedUrl) =>
    () => TestCollectionList(
      CollectionState(
        rawCollections: [
          Collection(
            id: 'existing',
            name: '6 Minute English',
            createdDate: DateTime(2026, 1, 1),
            source: CollectionSource.podcast,
            podcastFeedUrl: feedUrl,
          ),
        ],
      ),
    );

void main() {
  testWidgets('进入页面时搜索框不会自动聚焦', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [discoverPodcastsProvider.overrideWith((ref) => const [])],
      ),
    );
    await tester.pumpAndSettle();

    final editableText = tester.widget<EditableText>(find.byType(EditableText));
    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('搜索框使用普通文本键盘并保留搜索提交动作', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [discoverPodcastsProvider.overrideWith((ref) => const [])],
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.text);
    expect(field.textInputAction, TextInputAction.search);
  });

  testWidgets('聚焦搜索框后点击页面其他区域会释放焦点', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [discoverPodcastsProvider.overrideWith((ref) => const [])],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editableText = tester.widget<EditableText>(find.byType(EditableText));
    expect(editableText.focusNode.hasFocus, isTrue);

    await tester.tap(find.byType(AppBar));
    await tester.pump();

    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('聚焦搜索框后开始滑动列表会自动释放焦点', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith(
            (ref) => [
              for (var index = 0; index < 20; index++)
                makeCatalogPodcast(id: 'p$index', title: 'Podcast $index'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editableText = tester.widget<EditableText>(find.byType(EditableText));
    expect(editableText.focusNode.hasFocus, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();

    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('搜索框为空时展示精选播客列表', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith(
            (ref) => [
              makeCatalogPodcast(id: 'p1', title: '6 Minute English'),
              makeCatalogPodcast(id: 'p2', title: 'VOA Learning English'),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('6 Minute English'), findsOneWidget);
    expect(find.text('VOA Learning English'), findsOneWidget);
  });

  testWidgets('输入关键词展示 Apple 搜索结果', (tester) async {
    final fakeSearch = _FakeSearchService([
      const PodcastSearchResult(
        id: 's1',
        title: 'BBC Global News',
        author: 'BBC',
        feedUrl: 'https://feeds.bbc.co.uk/news.xml',
      ),
    ]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith((ref) => const []),
          podcastSearchServiceProvider.overrideWithValue(fakeSearch),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bbc');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('BBC Global News'), findsOneWidget);
    expect(fakeSearch.lastTerm, 'bbc');
  });

  testWidgets('输入链接解析为可点 item（不再直接订阅链接）', (tester) async {
    const url = 'https://example.com/feed.xml';
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith((ref) => const []),
          podcastPreviewProvider(url).overrideWith(
            (ref) async => const PodcastPreviewData(
              meta: PodcastFeedMeta(
                title: 'Example Cast',
                feedUrl: url,
                author: 'Example Author',
              ),
              episodes: [
                PodcastEpisode(
                  guid: 'e1',
                  title: 'Ep',
                  enclosureUrl: 'https://example.com/e1.mp3',
                  enclosureType: 'audio/mpeg',
                ),
              ],
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 展示解析出的播客 item，而非旧的「订阅此链接」盲订阅卡片。
    expect(find.text('Example Cast'), findsOneWidget);
    expect(find.text('Subscribe to this link'), findsNothing);
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
  });

  testWidgets('点精选项的 + 订阅（传订阅输入 URL）后停留在本页', (tester) async {
    final fakeRepo = _FakePodcastRepository();
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith(
            (ref) => [
              makeCatalogPodcast(
                id: 'p1',
                title: '6 Minute English',
                applePodcastUrl: 'https://podcasts.apple.com/id262026947',
                rssUrl: 'https://feeds.bbci.co.uk/6min.rss',
              ),
            ],
          ),
          isAuthenticatedProvider.overrideWithValue(true),
          podcastRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.pumpAndSettle();

    // subscriptionInputUrl 优先 Apple 链接
    expect(fakeRepo.subscribed, ['https://podcasts.apple.com/id262026947']);
    expect(fakeRepo.knownFeedUrls, ['https://feeds.bbci.co.uk/6min.rss']);
    // 停留在本页：搜索框仍在，未发生导航。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Added to My Collections'), findsWidgets);
  });

  testWidgets('已订阅的精选项显示「去学习」', (tester) async {
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith(
            (ref) => [
              makeCatalogPodcast(
                id: 'p1',
                title: '6 Minute English',
                rssUrl: 'https://feeds.bbci.co.uk/6min.rss',
              ),
            ],
          ),
          collectionListProvider.overrideWith(
            _seeded('https://feeds.bbci.co.uk/6min.rss'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Start Practicing'), findsOneWidget);
    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
  });

  testWidgets('未登录点 + 弹登录提示且不订阅', (tester) async {
    final fakeRepo = _FakePodcastRepository();
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: [
          discoverPodcastsProvider.overrideWith(
            (ref) => [makeCatalogPodcast(id: 'p1', title: '6 Minute English')],
          ),
          isAuthenticatedProvider.overrideWithValue(false),
          podcastRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(fakeRepo.subscribed, isEmpty);
  });

  testWidgets('点 item 内容区打开单集预览页', (tester) async {
    await tester.pumpWidget(
      _routed(
        overrides: [
          discoverPodcastsProvider.overrideWith(
            (ref) => [
              makeCatalogPodcast(
                id: 'p1',
                title: '6 Minute English',
                rssUrl: 'https://feeds.bbci.co.uk/6min.rss',
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('6 Minute English'));
    await tester.pumpAndSettle();

    expect(find.text('PREVIEW:6 Minute English'), findsOneWidget);
  });
}

/// 带 GoRouter 的最小宿主：验证 pushNested 打开预览子路由。
Widget _routed({required List<Override> overrides}) {
  final router = GoRouter(
    initialLocation: '/podcast-subscribe',
    routes: [
      GoRoute(
        path: '/podcast-subscribe',
        builder: (context, state) => const PodcastDiscoveryScreen(),
        routes: [
          GoRoute(
            path: 'preview',
            builder: (context, state) {
              final arg = state.extra as PodcastPreviewArg?;
              return Scaffold(body: Text('PREVIEW:${arg?.title ?? '-'}'));
            },
          ),
        ],
      ),
      GoRoute(
        path: '/collections/:id',
        builder: (context, state) => const Scaffold(body: Text('COLLECTION')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      collectionListProvider.overrideWith(() => TestCollectionList()),
      ...overrides,
    ],
    child: MaterialApp.router(
      locale: const Locale('en'),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light(),
      routerConfig: router,
    ),
  );
}
