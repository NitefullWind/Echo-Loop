import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../memory_scheduler/domain/memory_namespaces.dart';
import '../memory_scheduler/domain/memory_rating.dart';
import '../memory_scheduler/domain/review_retention.dart';
import '../../models/study_stage.dart';

/// 统计筛选范围。
enum ReviewStatisticsScope { all, sentences, vocabulary }

/// 单日复习统计。
class ReviewStatisticsDay {
  final DateTime date;
  final int reviewedCards;
  final int seconds;

  const ReviewStatisticsDay({
    required this.date,
    required this.reviewedCards,
    required this.seconds,
  });
}

/// 评分分布。
class ReviewRatingDistribution {
  final int again;
  final int hard;
  final int good;
  final int easy;

  const ReviewRatingDistribution({
    this.again = 0,
    this.hard = 0,
    this.good = 0,
    this.easy = 0,
  });

  int get total => again + hard + good + easy;
}

/// 复习统计页面所需的聚合结果。
class ReviewStatistics {
  final int todayReviewedCards;
  final int todaySeconds;
  final int dueNow;
  final int overdueNow;
  final int streak;
  final double retentionRate;
  final ReviewRatingDistribution ratings;
  final int totalSentences;
  final int totalVocabulary;
  final List<ReviewStatisticsDay> dailyTrend;
  final List<int> upcomingDue;

  const ReviewStatistics({
    this.todayReviewedCards = 0,
    this.todaySeconds = 0,
    this.dueNow = 0,
    this.overdueNow = 0,
    this.streak = 0,
    this.retentionRate = 0,
    this.ratings = const ReviewRatingDistribution(),
    this.totalSentences = 0,
    this.totalVocabulary = 0,
    this.dailyTrend = const [],
    this.upcomingDue = const [],
  });
}

/// 收藏复习统计的只读数据聚合层。
class ReviewStatisticsRepository {
  final AppDatabase _db;

  ReviewStatisticsRepository(this._db);

  Future<ReviewStatistics> load({
    required DateTime now,
    ReviewStatisticsScope scope = ReviewStatisticsScope.all,
  }) async {
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: 29));
    final end = today.add(const Duration(days: 1));
    final events = await _readEvents(start: start, end: end);
    final allEvents = await _readEvents();
    final schedules = await _db.select(_db.memorySchedules).get();
    final scheduleById = {for (final row in schedules) row.id: row};
    final validVocabularySubjects = await _readValidVocabularySubjects();
    bool matches(String scheduleId) {
      final schedule = scheduleById[scheduleId];
      final vocabularySubject = schedule == null
          ? null
          : _subjectKey(schedule.namespace, schedule.subjectId);
      return switch (scope) {
        ReviewStatisticsScope.all =>
          schedule?.namespace == kSavedSentenceNamespace ||
              validVocabularySubjects.contains(vocabularySubject),
        ReviewStatisticsScope.sentences =>
          schedule?.namespace == kSavedSentenceNamespace,
        ReviewStatisticsScope.vocabulary => validVocabularySubjects.contains(
          vocabularySubject,
        ),
      };
    }

    final filteredEvents = events
        .where((event) => matches(event.scheduleId))
        .toList();
    final filteredAllEvents = allEvents
        .where((event) => matches(event.scheduleId))
        .toList();
    final firstByDayAndCard = <String, _ReviewEvent>{};
    for (final event in filteredEvents) {
      final local = event.reviewedAt.toLocal();
      final key =
          '${event.scheduleId}:${local.year}-${local.month}-${local.day}';
      final previous = firstByDayAndCard[key];
      if (previous == null || event.reviewedAt.isBefore(previous.reviewedAt)) {
        firstByDayAndCard[key] = event;
      }
    }
    final firstEvents = firstByDayAndCard.values.toList();
    int dayCount(DateTime date) => firstEvents
        .where((event) {
          final local = event.reviewedAt.toLocal();
          return local.year == date.year &&
              local.month == date.month &&
              local.day == date.day;
        })
        .map((event) => event.scheduleId)
        .toSet()
        .length;

    final stageRows = [
      for (
        var date = start;
        !date.isAfter(today);
        date = date.add(const Duration(days: 1))
      )
        ...await _db.dailyStageStudyRecordDao.getByDate(date),
    ];
    final secondsByDay = <DateTime, int>{};
    for (final row in stageRows) {
      // 复习统计只计算收藏复习阶段，避免普通学习时长污染筛选结果。
      final stageMatches = switch (scope) {
        ReviewStatisticsScope.all =>
          row.stage == StudyStage.savedSentencesReview ||
              row.stage == StudyStage.savedVocabularyReview,
        ReviewStatisticsScope.sentences =>
          row.stage == StudyStage.savedSentencesReview,
        ReviewStatisticsScope.vocabulary =>
          row.stage == StudyStage.savedVocabularyReview,
      };
      if (stageMatches) {
        secondsByDay[row.date] =
            (secondsByDay[row.date] ?? 0) + row.studyTimeMilliseconds ~/ 1000;
      }
    }
    final trend = List.generate(30, (index) {
      final date = start.add(Duration(days: index));
      return ReviewStatisticsDay(
        date: date,
        reviewedCards: dayCount(date),
        seconds: secondsByDay[date] ?? 0,
      );
    });
    final todayEvents = firstEvents.where((event) {
      final local = event.reviewedAt.toLocal();
      return local.year == today.year &&
          local.month == today.month &&
          local.day == today.day;
    }).toList();
    final retention = ReviewRetentionCalculator.calculate(
      filteredEvents.map(
        (event) => ReviewRetentionEvent(
          subjectId: event.scheduleId,
          rating: _memoryRating(event.rating),
        ),
      ),
    );
    final ratings = ReviewRatingDistribution(
      again: retention.againUniqueItems,
      hard: retention.hardUniqueItems,
      good: retention.goodUniqueItems,
      easy: retention.easyUniqueItems,
    );
    final active = schedules.where(
      (row) => row.status == 'active' && matches(row.id),
    );
    final dueNow = active
        .where((row) => !row.dueAt.isAfter(now.toUtc()))
        .length;
    final upcoming = List.generate(7, (index) {
      final date = today.add(Duration(days: index));
      return active.where((row) {
        final local = row.dueAt.toLocal();
        return local.year == date.year &&
            local.month == date.month &&
            local.day == date.day;
      }).length;
    });
    final overdueNow = active
        .where(
          (row) => row.dueAt.toLocal().isBefore(
            DateTime(today.year, today.month, today.day),
          ),
        )
        .length;
    final reviewedDays = <DateTime>{};
    for (final event in filteredAllEvents) {
      final local = event.reviewedAt.toLocal();
      reviewedDays.add(DateTime(local.year, local.month, local.day));
    }
    var streak = 0;
    for (
      var date = today;
      reviewedDays.contains(date);
      date = date.subtract(const Duration(days: 1))
    ) {
      streak++;
    }
    final uniqueSubjects = <String, String>{};
    for (final event in filteredAllEvents) {
      final schedule = scheduleById[event.scheduleId];
      if (schedule != null) {
        uniqueSubjects[event.scheduleId] = schedule.namespace;
      }
    }
    return ReviewStatistics(
      todayReviewedCards: todayEvents.map((e) => e.scheduleId).toSet().length,
      todaySeconds: secondsByDay[today] ?? 0,
      dueNow: dueNow,
      overdueNow: overdueNow,
      streak: streak,
      retentionRate: retention.retentionRate,
      ratings: ratings,
      totalSentences: uniqueSubjects.values
          .where((n) => n == kSavedSentenceNamespace)
          .length,
      totalVocabulary: uniqueSubjects.values
          .where((n) => n != kSavedSentenceNamespace)
          .length,
      dailyTrend: trend,
      upcomingDue: upcoming,
    );
  }

  Future<List<_ReviewEvent>> _readEvents({
    DateTime? start,
    DateTime? end,
  }) async {
    final predicates = <String>[];
    final variables = <Variable<Object>>[];
    if (start != null) {
      predicates.add('reviewed_at >= ?');
      variables.add(Variable.withDateTime(start.toUtc()));
    }
    if (end != null) {
      predicates.add('reviewed_at < ?');
      variables.add(Variable.withDateTime(end.toUtc()));
    }
    final where = predicates.isEmpty
        ? ''
        : ' WHERE ${predicates.join(' AND ')}';
    final rows = await _db
        .customSelect(
          'SELECT schedule_id, sequence, rating, reviewed_at '
          'FROM memory_review_events$where '
          'ORDER BY reviewed_at ASC, sequence ASC',
          variables: variables,
        )
        .get();
    return rows
        .map(
          (row) => _ReviewEvent(
            scheduleId: row.read<String>('schedule_id'),
            sequence: row.read<int>('sequence'),
            rating: row.read<String>('rating'),
            reviewedAt: row.read<DateTime>('reviewed_at'),
          ),
        )
        .toList(growable: false);
  }

  /// 统计词汇前先对齐复习入口：软删除、缺失主体 ID 或空展示文本的内容
  /// 都不能让历史 active 调度继续出现在待复习与统计里。
  Future<Set<String>> _readValidVocabularySubjects() async {
    final words = await _db.savedWordDao.getAll();
    final phrases = await _db.savedSenseGroupDao.getAll();
    return {
      for (final word in words)
        if (word.word.trim().isNotEmpty &&
            word.memorySubjectId != null &&
            word.memorySubjectId!.isNotEmpty)
          _subjectKey(kSavedWordOrPhraseNamespace, word.memorySubjectId!),
      for (final phrase in phrases)
        if (phrase.displayText.trim().isNotEmpty &&
            phrase.memorySubjectId != null &&
            phrase.memorySubjectId!.isNotEmpty)
          _subjectKey(kSavedSenseGroupNamespace, phrase.memorySubjectId!),
    };
  }
}

String _subjectKey(String namespace, String subjectId) =>
    '$namespace:$subjectId';

class _ReviewEvent {
  final String scheduleId;
  final int sequence;
  final String rating;
  final DateTime reviewedAt;

  const _ReviewEvent({
    required this.scheduleId,
    required this.sequence,
    required this.rating,
    required this.reviewedAt,
  });
}

MemoryRating _memoryRating(String value) => switch (value) {
  'again' => MemoryRating.again,
  'hard' => MemoryRating.hard,
  'good' => MemoryRating.good,
  'easy' => MemoryRating.easy,
  _ => throw StateError('未知复习评分: $value'),
};
