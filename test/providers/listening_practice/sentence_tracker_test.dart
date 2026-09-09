import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/models/sentence.dart';
import 'package:echo_loop/providers/listening_practice/sentence_tracker.dart';

void main() {
  group('SentenceTracker', () {
    // 创建句子列表：0-5s, 5-10s, 10-15s, 15-20s, 20-25s
    List<Sentence> createSentences(int count) {
      return List.generate(
        count,
        (i) => Sentence(
          index: i,
          text: '句子 $i',
          startTime: Duration(seconds: i * 5),
          endTime: Duration(seconds: (i + 1) * 5),
        ),
      );
    }

    // 创建带间隙的句子列表：0-3s, 5-8s, 10-13s
    List<Sentence> createSentencesWithGaps() {
      return [
        Sentence(
          index: 0,
          text: '句子 0',
          startTime: const Duration(seconds: 0),
          endTime: const Duration(seconds: 3),
        ),
        Sentence(
          index: 1,
          text: '句子 1',
          startTime: const Duration(seconds: 5),
          endTime: const Duration(seconds: 8),
        ),
        Sentence(
          index: 2,
          text: '句子 2',
          startTime: const Duration(seconds: 10),
          endTime: const Duration(seconds: 13),
        ),
      ];
    }

    group('findSentenceIndexByPosition', () {
      test('空列表返回 -1', () {
        final result = SentenceTracker.findSentenceIndexByPosition(
          [],
          const Duration(seconds: 5),
        );
        expect(result, -1);
      });

      test('位置在第一个句子之前返回 0', () {
        // 句子从 5s 开始，位置在 2s
        final sentences = [
          Sentence(
            index: 0,
            text: '句子 0',
            startTime: const Duration(seconds: 5),
            endTime: const Duration(seconds: 10),
          ),
        ];
        final result = SentenceTracker.findSentenceIndexByPosition(
          sentences,
          const Duration(seconds: 2),
        );
        expect(result, 0);
      });

      test('位置在最后一个句子之后返回 last index', () {
        final sentences = createSentences(3);
        final result = SentenceTracker.findSentenceIndexByPosition(
          sentences,
          const Duration(seconds: 30), // 超过最后一个句子的 endTime (15s)
        );
        expect(result, 2); // last index
      });

      test('精确落在某个句子内返回该句子', () {
        final sentences = createSentences(5);
        // 位置 12s 落在句子 2（10-15s）内
        final result = SentenceTracker.findSentenceIndexByPosition(
          sentences,
          const Duration(seconds: 12),
        );
        expect(result, 2);
      });

      test('位置正好在句子起点', () {
        final sentences = createSentences(5);
        // 位置 10s = 句子 2 的 startTime
        final result = SentenceTracker.findSentenceIndexByPosition(
          sentences,
          const Duration(seconds: 10),
        );
        expect(result, 2);
      });

      test('落在两个句子间隙归属上一句（尾部静音）', () {
        final sentences = createSentencesWithGaps();
        // 位置 4s 在句子 0（0-3s）和句子 1（5-8s）之间的间隙；归属上一句 0，
        // 避免静音段高亮提前跳到下一句。
        final result = SentenceTracker.findSentenceIndexByPosition(
          sentences,
          const Duration(seconds: 4),
        );
        expect(result, 0); // 上一句（间隙是其尾部静音）
      });

      test('恰好落在某句 endTime（区间右开）归属上一句', () {
        final sentences = createSentencesWithGaps();
        // 位置 3s = 句子 0 的 endTime，区间 [start, end) 右开，3s 不属于句子 0；
        // 处于句子 0 与 1 之间的间隙，归属上一句 0。
        final result = SentenceTracker.findSentenceIndexByPosition(
          sentences,
          const Duration(seconds: 3),
        );
        expect(result, 0);
      });

      test('单个句子的情况', () {
        final sentences = [
          Sentence(
            index: 0,
            text: '唯一句子',
            startTime: const Duration(seconds: 5),
            endTime: const Duration(seconds: 10),
          ),
        ];

        // 在句子内
        expect(
          SentenceTracker.findSentenceIndexByPosition(
            sentences,
            const Duration(seconds: 7),
          ),
          0,
        );

        // 在句子前
        expect(
          SentenceTracker.findSentenceIndexByPosition(
            sentences,
            const Duration(seconds: 2),
          ),
          0,
        );

        // 在句子后
        expect(
          SentenceTracker.findSentenceIndexByPosition(
            sentences,
            const Duration(seconds: 15),
          ),
          0,
        );
      });
    });

    group('findClosestBookmark', () {
      test('空列表返回 null', () {
        final result = SentenceTracker.findClosestBookmark(
          [],
          const Duration(seconds: 5),
        );
        expect(result, isNull);
      });

      test('返回最接近的书签', () {
        final bookmarked = [
          Sentence(
            index: 0,
            text: '书签 0',
            startTime: const Duration(seconds: 0),
            endTime: const Duration(seconds: 5),
            isBookmarked: true,
          ),
          Sentence(
            index: 5,
            text: '书签 5',
            startTime: const Duration(seconds: 25),
            endTime: const Duration(seconds: 30),
            isBookmarked: true,
          ),
          Sentence(
            index: 8,
            text: '书签 8',
            startTime: const Duration(seconds: 40),
            endTime: const Duration(seconds: 45),
            isBookmarked: true,
          ),
        ];
        // 位置 27s，最接近书签 5（startTime=25s）
        final result = SentenceTracker.findClosestBookmark(
          bookmarked,
          const Duration(seconds: 27),
        );
        expect(result, 5);
      });

      test('多个等距书签返回第一个', () {
        final bookmarked = [
          Sentence(
            index: 0,
            text: '书签 0',
            startTime: const Duration(seconds: 0),
            endTime: const Duration(seconds: 5),
            isBookmarked: true,
          ),
          Sentence(
            index: 2,
            text: '书签 2',
            startTime: const Duration(seconds: 10),
            endTime: const Duration(seconds: 15),
            isBookmarked: true,
          ),
        ];
        // 位置 5s，距 书签 0(0s) 和 书签 2(10s) 等距
        final result = SentenceTracker.findClosestBookmark(
          bookmarked,
          const Duration(seconds: 5),
        );
        // 因为使用 < (严格小于)，等距时保持第一个
        expect(result, 0);
      });
    });

    group('findSentencesCompletedBetween', () {
      test('返回区间内所有自然结束的句子并包含右边界', () {
        final sentences = createSentencesWithGaps();

        final result = SentenceTracker.findSentencesCompletedBetween(
          sentences,
          const Duration(seconds: 2),
          const Duration(seconds: 10),
        );

        expect(result.map((sentence) => sentence.index), [0, 1]);
      });

      test('相同位置或倒退位置不重复返回句子', () {
        final sentences = createSentences(3);

        expect(
          SentenceTracker.findSentencesCompletedBetween(
            sentences,
            const Duration(seconds: 5),
            const Duration(seconds: 5),
          ),
          isEmpty,
        );
        expect(
          SentenceTracker.findSentencesCompletedBetween(
            sentences,
            const Duration(seconds: 10),
            const Duration(seconds: 4),
          ),
          isEmpty,
        );
      });
    });
  });
}
