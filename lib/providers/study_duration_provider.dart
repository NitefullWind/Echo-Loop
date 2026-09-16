import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/providers.dart';

/// 学习时长统计粒度。
enum StudyDurationGranularity { day, week, month, year }

/// 一个连续时间周期内的学习时长统计。
@immutable
class StudyDurationBucket {
  final DateTime periodStart;
  final DateTime periodEnd;
  final int totalSeconds;
  final int inputSeconds;
  final int outputSeconds;
  final int otherSeconds;
  final bool isCurrentPeriod;

  const StudyDurationBucket({
    required this.periodStart,
    required this.periodEnd,
    required this.totalSeconds,
    required this.inputSeconds,
    required this.outputSeconds,
    required this.otherSeconds,
    required this.isCurrentPeriod,
  });
}

/// 从数据库读取一次日记录；粒度切换只重用此快照。
final studyDurationRecordsProvider = FutureProvider<List<DailyStudyRecord>>((
  ref,
) {
  return ref.read(dailyStudyRecordDaoProvider).getAll();
});

final studyDurationBucketsProvider =
    FutureProvider.family<List<StudyDurationBucket>, StudyDurationGranularity>((
      ref,
      granularity,
    ) async {
      final records = await ref.watch(studyDurationRecordsProvider.future);
      return StudyDurationRepository.aggregate(records, granularity);
    });

/// 将按日记录聚合为连续的日、周、月或年周期。
class StudyDurationRepository {
  const StudyDurationRepository._();

  static List<StudyDurationBucket> aggregate(
    List<DailyStudyRecord> records,
    StudyDurationGranularity granularity, {
    DateTime? now,
  }) {
    final today = _dateOnly(now ?? DateTime.now());
    final valid = records.where(_hasData).toList(growable: false);
    final currentStart = _periodStart(today, granularity);
    final firstStart = valid.isEmpty
        ? currentStart
        : _periodStart(valid.first.date, granularity);
    final values = <DateTime, List<int>>{};
    for (final record in valid) {
      final key = _periodStart(record.date, granularity);
      final value = values.putIfAbsent(key, () => [0, 0, 0]);
      value[0] += math.max(record.studyTimeMilliseconds ~/ 1000, 0);
      value[1] += math.max(record.inputTimeMilliseconds ~/ 1000, 0);
      value[2] += math.max(record.outputTimeMilliseconds ~/ 1000, 0);
    }

    final result = <StudyDurationBucket>[];
    var cursor = firstStart;
    while (!cursor.isAfter(currentStart)) {
      final raw = values[cursor] ?? const [0, 0, 0];
      final total = raw[0];
      var input = math.min(math.max(raw[1], 0), total);
      var output = math.min(math.max(raw[2], 0), total - input);
      if (raw[1] == 0 && raw[2] == 0 && total > 0) input = total;
      output = math.min(output, total - input);
      final end = _periodEnd(cursor, granularity, today);
      result.add(
        StudyDurationBucket(
          periodStart: cursor,
          periodEnd: end,
          totalSeconds: total,
          inputSeconds: input,
          outputSeconds: output,
          otherSeconds: total - input - output,
          isCurrentPeriod: cursor == currentStart,
        ),
      );
      cursor = _nextPeriod(cursor, granularity);
    }
    return result;
  }

  static bool _hasData(DailyStudyRecord r) =>
      r.studyTimeMilliseconds > 0 ||
      r.inputTimeMilliseconds > 0 ||
      r.outputTimeMilliseconds > 0;

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static DateTime _periodStart(
    DateTime date,
    StudyDurationGranularity granularity,
  ) {
    final day = _dateOnly(date);
    switch (granularity) {
      case StudyDurationGranularity.day:
        return day;
      case StudyDurationGranularity.week:
        return day.subtract(Duration(days: day.weekday - DateTime.monday));
      case StudyDurationGranularity.month:
        return DateTime(day.year, day.month);
      case StudyDurationGranularity.year:
        return DateTime(day.year);
    }
  }

  static DateTime _periodEnd(
    DateTime start,
    StudyDurationGranularity granularity,
    DateTime today,
  ) {
    final next = _nextPeriod(start, granularity);
    return _dateOnly(next.subtract(const Duration(days: 1))).isAfter(today)
        ? today
        : _dateOnly(next.subtract(const Duration(days: 1)));
  }

  static DateTime _nextPeriod(
    DateTime start,
    StudyDurationGranularity granularity,
  ) {
    switch (granularity) {
      case StudyDurationGranularity.day:
        return start.add(const Duration(days: 1));
      case StudyDurationGranularity.week:
        return start.add(const Duration(days: 7));
      case StudyDurationGranularity.month:
        return DateTime(start.year, start.month + 1);
      case StudyDurationGranularity.year:
        return DateTime(start.year + 1);
    }
  }
}
