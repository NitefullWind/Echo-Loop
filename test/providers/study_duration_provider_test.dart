import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/providers/study_duration_provider.dart';

void main() {
  DailyStudyRecord record(DateTime date, int total, int input, int output) =>
      DailyStudyRecord(
        id: 1,
        date: date,
        studyTimeSeconds: total,
        studyTimeMilliseconds: total * 1000,
        inputWords: 0,
        outputWords: 0,
        inputTimeSeconds: input,
        inputTimeMilliseconds: input * 1000,
        outputTimeSeconds: output,
        outputTimeMilliseconds: output * 1000,
      );

  test('按周聚合并修正分段总和', () {
    final buckets = StudyDurationRepository.aggregate(
      [
        record(DateTime(2026, 1, 5), 100, 80, 80),
        record(DateTime(2026, 1, 11), 50, 0, 0),
      ],
      StudyDurationGranularity.week,
      now: DateTime(2026, 1, 11),
    );
    expect(buckets.length, 1);
    expect(buckets.single.totalSeconds, 150);
    expect(buckets.single.inputSeconds, 80);
    expect(buckets.single.outputSeconds, 70);
    expect(buckets.single.otherSeconds, 0);
    expect(buckets.single.isCurrentPeriod, isTrue);
  });

  test('跨月到当前月份之间补零', () {
    final buckets = StudyDurationRepository.aggregate(
      [record(DateTime(2025, 12, 31), 60, 20, 10)],
      StudyDurationGranularity.month,
      now: DateTime(2026, 2, 2),
    );
    expect(buckets.map((bucket) => bucket.totalSeconds), [60, 0, 0]);
    expect(buckets.last.isCurrentPeriod, isTrue);
  });

  test('空数据库从当前周期开始', () {
    final buckets = StudyDurationRepository.aggregate(
      const [],
      StudyDurationGranularity.day,
      now: DateTime(2026, 2, 2),
    );
    expect(buckets.length, 1);
    expect(buckets.single.totalSeconds, 0);
  });
}
