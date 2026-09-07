import 'package:drift/drift.dart';

import '../../models/study_stage.dart';
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

  /// UPSERT 累加指定日期和阶段的学习统计
  ///
  /// 如果该日期+阶段不存在则插入新行，否则在现有值上累加。
  /// 所有参数默认为 0，只传需要增加的字段即可。
  Future<void> upsertAdd(
    DateTime date,
    StudyStage stage, {
    int studyTime = 0,
    int inputTime = 0,
    int outputTime = 0,
    int studyTimeMilliseconds = 0,
    int inputTimeMilliseconds = 0,
    int outputTimeMilliseconds = 0,
  }) async {
    final dateOnly = _dateOnly(date);
    await transaction(() async {
      final existing =
          await (select(dailyStageStudyRecords)..where(
                (t) => t.date.equals(dateOnly) & t.stage.equalsValue(stage),
              ))
              .getSingleOrNull();

      if (existing == null) {
        await into(dailyStageStudyRecords).insert(
          DailyStageStudyRecordsCompanion.insert(
            date: dateOnly,
            stage: stage,
            studyTimeSeconds: Value(studyTime),
            inputTimeSeconds: Value(inputTime),
            outputTimeSeconds: Value(outputTime),
            studyTimeMilliseconds: Value(studyTimeMilliseconds),
            inputTimeMilliseconds: Value(inputTimeMilliseconds),
            outputTimeMilliseconds: Value(outputTimeMilliseconds),
          ),
        );
      } else {
        await (update(
          dailyStageStudyRecords,
        )..where((t) => t.id.equals(existing.id))).write(
          DailyStageStudyRecordsCompanion(
            studyTimeSeconds: Value(existing.studyTimeSeconds + studyTime),
            inputTimeSeconds: Value(existing.inputTimeSeconds + inputTime),
            outputTimeSeconds: Value(existing.outputTimeSeconds + outputTime),
            studyTimeMilliseconds: Value(
              existing.studyTimeMilliseconds + studyTimeMilliseconds,
            ),
            inputTimeMilliseconds: Value(
              existing.inputTimeMilliseconds + inputTimeMilliseconds,
            ),
            outputTimeMilliseconds: Value(
              existing.outputTimeMilliseconds + outputTimeMilliseconds,
            ),
          ),
        );
      }
    });
  }

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
