import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/daily_stage_study_records.dart';

part 'daily_stage_study_record_dao.g.dart';

/// 每日分阶段学习记录 DAO
///
/// 提供 UPSERT 累加和按日期查询功能。
@DriftAccessor(tables: [DailyStageStudyRecords])
class DailyStageStudyRecordDao extends DatabaseAccessor<AppDatabase>
    with _$DailyStageStudyRecordDaoMixin {
  DailyStageStudyRecordDao(super.db);

  /// 截断时间部分，只保留日期
  DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  /// 查询日期范围内的阶段记录，包含首尾日期并忽略时分秒。
  Future<List<DailyStageStudyRecord>> getInDateRange(
    DateTime start,
    DateTime end,
  ) {
    return (select(dailyStageStudyRecords)..where(
          (t) => t.date.isBetweenValues(_dateOnly(start), _dateOnly(end)),
        ))
        .get();
  }

  /// 获取指定日期的所有阶段学习记录
  Future<List<DailyStageStudyRecord>> getByDate(DateTime date) {
    final dateOnly = _dateOnly(date);
    return (select(dailyStageStudyRecords)
          ..where((t) => t.date.equals(dateOnly))
          ..orderBy([(t) => OrderingTerm.asc(t.stage)]))
        .get();
  }
}
