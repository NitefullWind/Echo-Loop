import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/daily_study_records.dart';

part 'daily_study_record_dao.g.dart';

/// 每日学习记录 DAO
///
/// 提供 UPSERT 累加、单日查询、范围查询和连续天数计算。
@DriftAccessor(tables: [DailyStudyRecords])
class DailyStudyRecordDao extends DatabaseAccessor<AppDatabase>
    with _$DailyStudyRecordDaoMixin {
  DailyStudyRecordDao(super.db);

  /// 截断时间部分，只保留日期
  DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  /// 获取指定日期的学习记录
  ///
  /// 不存在时返回 null。
  Future<DailyStudyRecord?> getByDate(DateTime date) {
    final dateOnly = _dateOnly(date);
    return (select(
      dailyStudyRecords,
    )..where((t) => t.date.equals(dateOnly))).getSingleOrNull();
  }

  /// 获取指定日期范围内的学习记录（含 start 和 end）
  Future<List<DailyStudyRecord>> getBetween(DateTime start, DateTime end) {
    final startOnly = _dateOnly(start);
    final endOnly = _dateOnly(end);
    return (select(dailyStudyRecords)
          ..where(
            (t) =>
                t.date.isBiggerOrEqualValue(startOnly) &
                t.date.isSmallerOrEqualValue(endOnly),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.date)]))
        .get();
  }

  /// 获取全部按日学习记录，按日期升序返回。
  Future<List<DailyStudyRecord>> getAll() {
    return (select(
      dailyStudyRecords,
    )..orderBy([(t) => OrderingTerm.asc(t.date)])).get();
  }

  /// 计算连续学习天数（streak）
  ///
  /// 从昨天往回数连续有学习记录的天数，今天有学习则 +1。
  /// 上限 365 天。
  Future<int> getStreak({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());

    // 查询今天是否有记录
    final todayRecord = await getByDate(today);
    int streak = 0;
    if (todayRecord != null && todayRecord.studyTimeMilliseconds > 0) {
      streak = 1;
    }

    // 从昨天开始往回数
    for (int i = 1; i <= 365; i++) {
      final date = today.subtract(Duration(days: i));
      final record = await getByDate(date);
      if (record == null || record.studyTimeMilliseconds <= 0) break;
      streak++;
    }

    return streak;
  }
}
