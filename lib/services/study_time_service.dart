import '../database/daos/daily_study_record_dao.dart';
import '../database/daos/daily_stage_study_record_dao.dart';
import '../models/study_stage.dart';

/// 学习时长存储服务
///
/// 使用 Drift (SQLite) daily_study_records 表按日累计学习统计。
/// 每天一行，5 个计数器（学习时长、输入/输出词数、输入/输出时间）。
/// 可选传入 [StudyStage] 实现双写：总量表 + 阶段明细表。
class StudyTimeService {
  final DailyStudyRecordDao _dao;
  final DailyStageStudyRecordDao _stageDao;

  StudyTimeService(this._dao, this._stageDao);

  /// 获取指定日期的学习时长（秒）
  Future<int> getStudyTime(DateTime date) async {
    final record = await _dao.getByDate(date);
    if (record == null) return 0;
    return _durationSeconds(record.studyTimeMilliseconds, record.studyTimeSeconds);
  }

  /// 获取今日学习时长（秒）
  Future<int> getTodayStudyTime() => getStudyTime(DateTime.now());

  /// 累加学习时长（秒）到指定日期
  ///
  /// [seconds] 必须 > 0，否则忽略。
  /// [date] 默认为今天。
  /// [stage] 可选，传入时同时写入阶段明细表。
  Future<void> addStudyTime(
    int seconds, {
    DateTime? date,
    StudyStage? stage,
  }) async {
    if (seconds <= 0) return;
    final d = date ?? DateTime.now();
    await _dao.upsertAdd(d, studyTime: seconds, studyTimeMilliseconds: seconds * 1000);
    if (stage != null) {
      await _stageDao.upsertAdd(d, stage, studyTime: seconds, studyTimeMilliseconds: seconds * 1000);
    }
  }

  /// 按毫秒累加学习时长，保留不足一秒的播放时间。
  Future<void> addStudyDuration(Duration duration, {DateTime? date, StudyStage? stage}) async {
    final milliseconds = duration.inMilliseconds;
    if (milliseconds <= 0) return;
    final seconds = milliseconds ~/ 1000;
    final d = date ?? DateTime.now();
    await _dao.upsertAdd(d, studyTime: seconds, studyTimeMilliseconds: milliseconds);
    if (stage != null) {
      await _stageDao.upsertAdd(d, stage, studyTime: seconds, studyTimeMilliseconds: milliseconds);
    }
  }

  /// 获取连续学习天数（streak）
  ///
  /// 从昨天往回数连续有学习记录的天数，今天有学习则 +1。
  Future<int> getStudyStreak({DateTime? now}) {
    return _dao.getStreak(now: now);
  }

  /// 获取过去 7 天每天的学习时长（秒）
  ///
  /// 返回长度为 7 的列表，索引 0 = 6 天前，索引 6 = 今天。
  Future<List<int>> getWeeklyStudyTimes({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final start = today.subtract(const Duration(days: 6));
    final records = await _dao.getBetween(start, today);

    // 按日期建立查找表
    final Map<int, int> dayMap = {};
    for (final r in records) {
      final key = _dayKey(r.date);
      dayMap[key] = _durationSeconds(r.studyTimeMilliseconds, r.studyTimeSeconds);
    }

    final result = <int>[];
    for (int i = 6; i >= 0; i--) {
      final date = today.subtract(Duration(days: i));
      result.add(dayMap[_dayKey(date)] ?? 0);
    }
    return result;
  }

  /// 获取本周一至今的累计学习时长（秒）
  Future<int> getWeekTotalStudyTime({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final daysSinceMonday = today.weekday - 1;
    final monday = today.subtract(Duration(days: daysSinceMonday));
    final records = await _dao.getBetween(monday, today);

    int total = 0;
    for (final r in records) {
      total += _durationSeconds(r.studyTimeMilliseconds, r.studyTimeSeconds);
    }
    return total;
  }

  // ========== 输入词数 ==========

  /// 获取指定日期的输入词数
  Future<int> getInputWords(DateTime date) async {
    final record = await _dao.getByDate(date);
    return record?.inputWords ?? 0;
  }

  /// 获取今日输入词数
  Future<int> getTodayInputWords() => getInputWords(DateTime.now());

  /// 累加输入词数到指定日期
  ///
  /// [count] 必须 > 0，否则忽略。
  Future<void> addInputWords(int count, {DateTime? date}) async {
    if (count <= 0) return;
    await _dao.upsertAdd(date ?? DateTime.now(), inputWords: count);
  }

  // ========== 输出词数 ==========

  /// 获取指定日期的输出词数
  Future<int> getOutputWords(DateTime date) async {
    final record = await _dao.getByDate(date);
    return record?.outputWords ?? 0;
  }

  /// 获取今日输出词数
  Future<int> getTodayOutputWords() => getOutputWords(DateTime.now());

  /// 累加输出词数到指定日期
  ///
  /// [count] 必须 > 0，否则忽略。
  Future<void> addOutputWords(int count, {DateTime? date}) async {
    if (count <= 0) return;
    await _dao.upsertAdd(date ?? DateTime.now(), outputWords: count);
  }

  // ========== 输入时间（秒） ==========

  /// 获取指定日期的输入时间（秒）
  Future<int> getInputTime(DateTime date) async {
    final record = await _dao.getByDate(date);
    if (record == null) return 0;
    return _durationSeconds(record.inputTimeMilliseconds, record.inputTimeSeconds);
  }

  /// 获取今日输入时间（秒）
  Future<int> getTodayInputTime() => getInputTime(DateTime.now());

  /// 累加输入时间（秒）到指定日期
  ///
  /// [seconds] 必须 > 0，否则忽略。
  /// [stage] 可选，传入时同时写入阶段明细表。
  Future<void> addInputTime(
    int seconds, {
    DateTime? date,
    StudyStage? stage,
  }) async {
    if (seconds <= 0) return;
    final d = date ?? DateTime.now();
    await _dao.upsertAdd(d, inputTime: seconds, inputTimeMilliseconds: seconds * 1000);
    if (stage != null) {
      await _stageDao.upsertAdd(d, stage, inputTime: seconds, inputTimeMilliseconds: seconds * 1000);
    }
  }

  /// 按毫秒累加输入时间。
  Future<void> addInputDuration(Duration duration, {DateTime? date, StudyStage? stage}) async {
    final milliseconds = duration.inMilliseconds;
    if (milliseconds <= 0) return;
    final seconds = milliseconds ~/ 1000;
    final d = date ?? DateTime.now();
    await _dao.upsertAdd(d, inputTime: seconds, inputTimeMilliseconds: milliseconds);
    if (stage != null) {
      await _stageDao.upsertAdd(d, stage, inputTime: seconds, inputTimeMilliseconds: milliseconds);
    }
  }

  /// 获取过去 7 天每天的输入时间（秒）
  ///
  /// 返回长度为 7 的列表，索引 0 = 6 天前，索引 6 = 今天。
  Future<List<int>> getWeeklyInputTimes({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final start = today.subtract(const Duration(days: 6));
    final records = await _dao.getBetween(start, today);

    final Map<int, int> dayMap = {};
    for (final r in records) {
      dayMap[_dayKey(r.date)] = _durationSeconds(
        r.inputTimeMilliseconds,
        r.inputTimeSeconds,
      );
    }

    final result = <int>[];
    for (int i = 6; i >= 0; i--) {
      final date = today.subtract(Duration(days: i));
      result.add(dayMap[_dayKey(date)] ?? 0);
    }
    return result;
  }

  // ========== 输出时间（秒） ==========

  /// 获取指定日期的输出时间（秒）
  Future<int> getOutputTime(DateTime date) async {
    final record = await _dao.getByDate(date);
    if (record == null) return 0;
    return _durationSeconds(record.outputTimeMilliseconds, record.outputTimeSeconds);
  }

  /// 获取今日输出时间（秒）
  Future<int> getTodayOutputTime() => getOutputTime(DateTime.now());

  /// 累加输出时间（秒）到指定日期
  ///
  /// [seconds] 必须 > 0，否则忽略。
  /// [stage] 可选，传入时同时写入阶段明细表。
  Future<void> addOutputTime(
    int seconds, {
    DateTime? date,
    StudyStage? stage,
  }) async {
    if (seconds <= 0) return;
    final d = date ?? DateTime.now();
    await _dao.upsertAdd(d, outputTime: seconds, outputTimeMilliseconds: seconds * 1000);
    if (stage != null) {
      await _stageDao.upsertAdd(d, stage, outputTime: seconds, outputTimeMilliseconds: seconds * 1000);
    }
  }

  /// 按毫秒累加输出时间。
  Future<void> addOutputDuration(Duration duration, {DateTime? date, StudyStage? stage}) async {
    final milliseconds = duration.inMilliseconds;
    if (milliseconds <= 0) return;
    final seconds = milliseconds ~/ 1000;
    final d = date ?? DateTime.now();
    await _dao.upsertAdd(d, outputTime: seconds, outputTimeMilliseconds: milliseconds);
    if (stage != null) {
      await _stageDao.upsertAdd(d, stage, outputTime: seconds, outputTimeMilliseconds: milliseconds);
    }
  }

  /// 获取过去 7 天每天的输出时间（秒）
  ///
  /// 返回长度为 7 的列表，索引 0 = 6 天前，索引 6 = 今天。
  Future<List<int>> getWeeklyOutputTimes({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final start = today.subtract(const Duration(days: 6));
    final records = await _dao.getBetween(start, today);

    final Map<int, int> dayMap = {};
    for (final r in records) {
      dayMap[_dayKey(r.date)] = _durationSeconds(
        r.outputTimeMilliseconds,
        r.outputTimeSeconds,
      );
    }

    final result = <int>[];
    for (int i = 6; i >= 0; i--) {
      final date = today.subtract(Duration(days: i));
      result.add(dayMap[_dayKey(date)] ?? 0);
    }
    return result;
  }

  // ========== 阶段明细查询 ==========

  /// 按阶段累加日期范围（含首尾）的原始秒数，按枚举顺序输出。
  /// 格式化和显示裁剪留给弹窗，避免逐日取整造成累计误差。
  Future<List<DailyStageStudyRecordData>> getStageBreakdownInRange(
    DateTime start,
    DateTime end,
  ) async {
    final records = await _stageDao.getInDateRange(start, end);
    final totals = <StudyStage, DailyStageStudyRecordData>{};
    for (final record in records) {
      final previous = totals[record.stage];
      totals[record.stage] = DailyStageStudyRecordData(
        stage: record.stage,
        studyTimeSeconds: (previous?.studyTimeSeconds ?? 0) +
            _durationSeconds(record.studyTimeMilliseconds, record.studyTimeSeconds),
        inputTimeSeconds: (previous?.inputTimeSeconds ?? 0) +
            _durationSeconds(record.inputTimeMilliseconds, record.inputTimeSeconds),
        outputTimeSeconds: (previous?.outputTimeSeconds ?? 0) +
            _durationSeconds(record.outputTimeMilliseconds, record.outputTimeSeconds),
      );
    }
    return [
      for (final stage in StudyStage.values)
        if (totals[stage] case final record?) record,
    ];
  }

  /// 获取指定日期的阶段明细列表
  ///
  /// 返回该日期所有有记录的阶段，按阶段序号排序。
  /// 时长优先使用累计毫秒字段，兼容没有毫秒数据的旧记录。
  /// 无记录时返回空列表。
  Future<List<DailyStageStudyRecordData>> getStageBreakdown(
    DateTime date,
  ) async {
    final records = await _stageDao.getByDate(date);
    return records
        .map(
          (r) => DailyStageStudyRecordData(
            stage: r.stage,
            studyTimeSeconds: _durationSeconds(
              r.studyTimeMilliseconds,
              r.studyTimeSeconds,
            ),
            inputTimeSeconds: _durationSeconds(
              r.inputTimeMilliseconds,
              r.inputTimeSeconds,
            ),
            outputTimeSeconds: _durationSeconds(
              r.outputTimeMilliseconds,
              r.outputTimeSeconds,
            ),
          ),
        )
        .toList();
  }

  /// 获取指定日期的总量记录（用于弹窗回退显示）
  Future<DailyTotalData?> getDayTotal(DateTime date) async {
    final record = await _dao.getByDate(date);
    if (record == null) return null;
    return DailyTotalData(
      studyTimeSeconds: _durationSeconds(record.studyTimeMilliseconds, record.studyTimeSeconds),
      inputTimeSeconds: _durationSeconds(record.inputTimeMilliseconds, record.inputTimeSeconds),
      outputTimeSeconds: _durationSeconds(record.outputTimeMilliseconds, record.outputTimeSeconds),
    );
  }

  /// 截断时间部分，只保留日期
  DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  int _durationSeconds(int milliseconds, int legacySeconds) =>
      milliseconds > 0 ? milliseconds ~/ 1000 : legacySeconds;

  /// 将日期转换为用于 Map key 的整数（yyyymmdd）
  int _dayKey(DateTime dt) => dt.year * 10000 + dt.month * 100 + dt.day;
}

/// 阶段明细数据（从 DAO 记录映射的简单值对象）
class DailyStageStudyRecordData {
  final StudyStage stage;
  final int studyTimeSeconds;
  final int inputTimeSeconds;
  final int outputTimeSeconds;

  const DailyStageStudyRecordData({
    required this.stage,
    required this.studyTimeSeconds,
    required this.inputTimeSeconds,
    required this.outputTimeSeconds,
  });
}

/// 每日总量数据（用于弹窗回退显示旧数据）
class DailyTotalData {
  final int studyTimeSeconds;
  final int inputTimeSeconds;
  final int outputTimeSeconds;

  const DailyTotalData({
    required this.studyTimeSeconds,
    required this.inputTimeSeconds,
    required this.outputTimeSeconds,
  });
}
