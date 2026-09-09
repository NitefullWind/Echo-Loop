import 'dart:async';

import '../database/daos/daily_study_record_dao.dart';
import '../database/daos/daily_stage_study_record_dao.dart';
import '../database/daos/study_statistics_dao.dart';
import '../models/study_stage.dart';
import '../utils/word_counter.dart';
import 'app_logger.dart';
import 'study_activity_gate.dart';

/// 学习统计事件服务。
///
/// 所有写入都先在调用点快照日期、阶段和前台资格，再进入同一个 FIFO
/// 队列。查询会等待提交前的队列尾部，因此读操作具备 read-after-write
/// 一致性；具体数据库事务由 [StudyStatisticsDao] 负责。
class StudyTimeService {
  final DailyStudyRecordDao _dao;
  final DailyStageStudyRecordDao _stageDao;
  late final StudyStatisticsDao _statisticsDao;

  Future<void> _queueTail = Future<void>.value();
  Future<void>? _flushInFlight;
  int _nextEventId = 0;
  final List<_StudyWriteFailure> _failures = <_StudyWriteFailure>[];

  StudyTimeService(
    this._dao,
    this._stageDao, {
    StudyStatisticsDao? statisticsDao,
    StudyActivityGate? activityGate,
  }) : _activityGate = activityGate {
    _statisticsDao = statisticsDao ?? StudyStatisticsDao(_dao.attachedDatabase);
  }

  /// 记录一次学习会话的总学习时长和输入时长。
  ///
  /// 两类时长属于同一个统计事件，使用一次 FIFO 入队和一次数据库事务，
  /// 但数值彼此独立：用户暂停播放后继续思考时，只增加学习时长，不增加输入时长。
  Future<void> recordSessionDurations({
    required Duration studyDuration,
    Duration inputDuration = Duration.zero,
    required StudyStage stage,
    DateTime? date,
  }) {
    final eventDate = date ?? DateTime.now();
    return _enqueue(
      StudyStatisticsDelta(
        date: eventDate,
        stage: stage,
        studyTimeMilliseconds: studyDuration.inMilliseconds,
        inputTimeMilliseconds: inputDuration.inMilliseconds,
      ),
    );
  }

  /// 记录前台有效学习时长；计时器已经完成前台过滤，本方法不会再次 gate。
  Future<void> recordActiveDuration(
    Duration duration, {
    required StudyStage stage,
    bool recordInputDuration = false,
    DateTime? date,
  }) {
    final eventDate = date ?? DateTime.now();
    return recordSessionDurations(
      studyDuration: duration,
      inputDuration: recordInputDuration ? duration : Duration.zero,
      stage: stage,
      date: eventDate,
    );
  }

  // 旧学习任务仍通过 StudyEventRecorder 使用这些入口。它们保留为兼容适配，
  // 内部统一进入新的 FIFO + 单事务写入链路，后续任务迁移时可逐步移除。

  /// 按秒累加总学习时长；[stage] 为空时只写日总量。
  Future<void> addStudyTime(int seconds, {DateTime? date, StudyStage? stage}) =>
      addStudyDuration(
        Duration(seconds: seconds),
        date: date,
        stage: stage,
      );

  /// 按毫秒累加总学习时长；[stage] 为空时只写日总量。
  Future<void> addStudyDuration(
    Duration duration, {
    DateTime? date,
    StudyStage? stage,
  }) {
    if (duration <= Duration.zero) return Future<void>.value();
    return _enqueueLegacyDelta(
      date: date,
      stage: stage,
      studyTimeMilliseconds: duration.inMilliseconds,
    );
  }

  /// 累加输入词数。
  Future<void> addInputWords(int count, {DateTime? date}) {
    if (count <= 0) return Future<void>.value();
    return _enqueueLegacyDelta(date: date, inputWords: count);
  }

  /// 累加输出词数。
  Future<void> addOutputWords(int count, {DateTime? date}) {
    if (count <= 0) return Future<void>.value();
    return _enqueueLegacyDelta(date: date, outputWords: count);
  }

  /// 按秒累加输入时长；[stage] 为空时只写日总量。
  Future<void> addInputTime(int seconds, {DateTime? date, StudyStage? stage}) =>
      addInputDuration(
        Duration(seconds: seconds),
        date: date,
        stage: stage,
      );

  /// 按毫秒累加输入时长；[stage] 为空时只写日总量。
  Future<void> addInputDuration(
    Duration duration, {
    DateTime? date,
    StudyStage? stage,
  }) {
    if (duration <= Duration.zero) return Future<void>.value();
    return _enqueueLegacyDelta(
      date: date,
      stage: stage,
      inputTimeMilliseconds: duration.inMilliseconds,
    );
  }

  /// 按秒累加输出时长；[stage] 为空时只写日总量。
  Future<void> addOutputTime(
    int seconds, {
    DateTime? date,
    StudyStage? stage,
  }) => addOutputDuration(
    Duration(seconds: seconds),
    date: date,
    stage: stage,
  );

  /// 按毫秒累加输出时长；[stage] 为空时只写日总量。
  Future<void> addOutputDuration(
    Duration duration, {
    DateTime? date,
    StudyStage? stage,
  }) {
    if (duration <= Duration.zero) return Future<void>.value();
    return _enqueueLegacyDelta(
      date: date,
      stage: stage,
      outputTimeMilliseconds: duration.inMilliseconds,
    );
  }

  /// 记录按句播放；词数和词形由服务统一从文本提取。
  Future<void> recordSentencePlayback({
    required Duration duration,
    required String text,
    required StudyStage stage,
    bool recordInputDuration = true,
    DateTime? date,
  }) {
    if (!_isForeground('sentence_playback')) return Future<void>.value();
    final eventDate = date ?? DateTime.now();
    final milliseconds = duration.inMilliseconds;
    final wordForms = _extractWordForms(text, eventDate);
    return _enqueue(
      StudyStatisticsDelta(
        date: eventDate,
        stage: stage,
        inputTimeMilliseconds: recordInputDuration ? milliseconds : 0,
        inputWords: countWords(text),
        wordForms: wordForms,
      ),
    );
  }

  /// 记录一次语音识别输出。
  Future<void> recordSpeechRecognition({
    required Duration duration,
    int producedWordCount = 0,
    required StudyStage stage,
    DateTime? date,
  }) {
    if (!_isForeground('speech_recognition')) return Future<void>.value();
    final eventDate = date ?? DateTime.now();
    return _enqueue(
      StudyStatisticsDelta(
        date: eventDate,
        stage: stage,
        outputTimeMilliseconds: duration.inMilliseconds,
        outputWords: producedWordCount,
      ),
    );
  }

  /// 记录输出词数事件。
  Future<void> recordOutputWords(
    int count, {
    required StudyStage stage,
    DateTime? date,
  }) {
    if (!_isForeground('output_words')) return Future<void>.value();
    final eventDate = date ?? DateTime.now();
    return _enqueue(
      StudyStatisticsDelta(date: eventDate, stage: stage, outputWords: count),
    );
  }

  /// 非阻塞提交按句播放事件；异常由队列保留到下一次 [flush] 报告。
  void submitSentencePlayback({
    required Duration duration,
    required String text,
    required StudyStage stage,
    bool recordInputDuration = true,
    DateTime? date,
  }) {
    unawaited(
      recordSentencePlayback(
        duration: duration,
        text: text,
        stage: stage,
        recordInputDuration: recordInputDuration,
        date: date,
      ).catchError((Object error, StackTrace stackTrace) {
        AppLogger.log(
          'StudyStatistics',
          'submit.failed error=$error\n$stackTrace',
        );
      }),
    );
  }

  /// 非阻塞提交语音识别事件。
  void submitSpeechRecognition({
    required Duration duration,
    int producedWordCount = 0,
    required StudyStage stage,
    DateTime? date,
  }) {
    unawaited(
      recordSpeechRecognition(
        duration: duration,
        producedWordCount: producedWordCount,
        stage: stage,
        date: date,
      ).catchError((Object error, StackTrace stackTrace) {
        AppLogger.log(
          'StudyStatistics',
          'submit.failed error=$error\n$stackTrace',
        );
      }),
    );
  }

  /// 非阻塞提交输出词数事件。
  void submitOutputWords(
    int count, {
    required StudyStage stage,
    DateTime? date,
  }) {
    unawaited(
      recordOutputWords(count, stage: stage, date: date).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        AppLogger.log(
          'StudyStatistics',
          'submit.failed error=$error\n$stackTrace',
        );
      }),
    );
  }

  /// 等待调用前已提交的事件；失败时抛出该批次最早的原始异常。
  ///
  /// 同一时刻的并发调用共享一个 flush future。flush 开始后提交的新事件
  /// 属于下一批，不会被当前调用隐式等待。
  Future<void> flush() {
    final active = _flushInFlight;
    if (active != null) return active;
    final boundary = _nextEventId;
    final queue = _queueTail;
    final operation = _finishFlush(queue, boundary);
    final scheduled = operation.whenComplete(() => _flushInFlight = null);
    _flushInFlight = scheduled;
    return scheduled;
  }

  Future<void> _finishFlush(Future<void> queue, int boundary) async {
    await queue;
    final failures = _failures
        .where((failure) => failure.id <= boundary)
        .toList();
    _failures.removeWhere((failure) => failure.id <= boundary);
    if (failures.isNotEmpty) {
      final failure = failures.first;
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }

  Future<void> _enqueue(StudyStatisticsDelta delta) {
    final eventId = ++_nextEventId;
    final result = Completer<void>();
    final event = _queueTail.then((_) async {
      try {
        await _statisticsDao.applyDelta(delta);
        result.complete();
      } catch (error, stackTrace) {
        _failures.add(_StudyWriteFailure(eventId, error, stackTrace));
        AppLogger.log(
          'StudyStatistics',
          'write.failed event=$eventId error=$error\n$stackTrace',
        );
        result.completeError(error, stackTrace);
      }
    });
    _queueTail = event.catchError((Object _) {});
    return result.future;
  }

  Future<void> _enqueueLegacyDelta({
    DateTime? date,
    StudyStage? stage,
    int studyTimeMilliseconds = 0,
    int inputTimeMilliseconds = 0,
    int outputTimeMilliseconds = 0,
    int inputWords = 0,
    int outputWords = 0,
  }) {
    return _enqueue(
      StudyStatisticsDelta(
        date: date ?? DateTime.now(),
        // 旧的仅日总量事件不会写阶段表，因此这里的占位阶段不会产生副作用。
        stage: stage ?? StudyStage.freePlayer,
        studyTimeMilliseconds: studyTimeMilliseconds,
        inputTimeMilliseconds: inputTimeMilliseconds,
        outputTimeMilliseconds: outputTimeMilliseconds,
        inputWords: inputWords,
        outputWords: outputWords,
      ),
    );
  }

  Future<T> _afterWrites<T>(Future<T> Function() query) async {
    await _queueTail;
    return query();
  }

  bool _isForeground(String eventName) {
    final gate = _activityGate;
    if (gate == null || gate.isForeground) return true;
    AppLogger.log(
      'StudyStatistics',
      'write.skipped reason=app_not_foreground event=$eventName',
    );
    return false;
  }

  final StudyActivityGate? _activityGate;

  Map<String, DateTime> _extractWordForms(String text, DateTime learnedAt) {
    final forms = <String, DateTime>{};
    for (final match in _wordPattern.allMatches(text)) {
      final wordForm = match.group(0)?.toLowerCase();
      if (wordForm != null) forms[wordForm] = learnedAt;
    }
    return forms;
  }

  static final RegExp _wordPattern = RegExp(r"[A-Za-z]+(?:['’-][A-Za-z]+)*");

  /// 获取指定日期的学习时长（秒）
  Future<int> getStudyTime(DateTime date) async {
    final record = await _afterWrites(() => _dao.getByDate(date));
    if (record == null) return 0;
    return _durationSeconds(
      record.studyTimeMilliseconds,
      record.studyTimeSeconds,
    );
  }

  /// 获取今日学习时长（秒）
  Future<int> getTodayStudyTime() => getStudyTime(DateTime.now());

  /// 获取连续学习天数（streak）
  ///
  /// 从昨天往回数连续有学习记录的天数，今天有学习则 +1。
  Future<int> getStudyStreak({DateTime? now}) {
    return _afterWrites(() => _dao.getStreak(now: now));
  }

  /// 获取过去 7 天每天的学习时长（秒）
  ///
  /// 返回长度为 7 的列表，索引 0 = 6 天前，索引 6 = 今天。
  Future<List<int>> getWeeklyStudyTimes({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final start = today.subtract(const Duration(days: 6));
    final records = await _afterWrites(() => _dao.getBetween(start, today));

    // 按日期建立查找表
    final Map<int, int> dayMap = {};
    for (final r in records) {
      final key = _dayKey(r.date);
      dayMap[key] = _durationSeconds(
        r.studyTimeMilliseconds,
        r.studyTimeSeconds,
      );
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
    final records = await _afterWrites(() => _dao.getBetween(monday, today));

    int total = 0;
    for (final r in records) {
      total += _durationSeconds(r.studyTimeMilliseconds, r.studyTimeSeconds);
    }
    return total;
  }

  // ========== 输入词数 ==========

  /// 获取指定日期的输入词数
  Future<int> getInputWords(DateTime date) async {
    final record = await _afterWrites(() => _dao.getByDate(date));
    return record?.inputWords ?? 0;
  }

  /// 获取今日输入词数
  Future<int> getTodayInputWords() => getInputWords(DateTime.now());

  // ========== 输出词数 ==========

  /// 获取指定日期的输出词数
  Future<int> getOutputWords(DateTime date) async {
    final record = await _afterWrites(() => _dao.getByDate(date));
    return record?.outputWords ?? 0;
  }

  /// 获取今日输出词数
  Future<int> getTodayOutputWords() => getOutputWords(DateTime.now());

  // ========== 输入时间（秒） ==========

  /// 获取指定日期的输入时间（秒）
  Future<int> getInputTime(DateTime date) async {
    final record = await _afterWrites(() => _dao.getByDate(date));
    if (record == null) return 0;
    return _durationSeconds(
      record.inputTimeMilliseconds,
      record.inputTimeSeconds,
    );
  }

  /// 获取今日输入时间（秒）
  Future<int> getTodayInputTime() => getInputTime(DateTime.now());

  /// 获取过去 7 天每天的输入时间（秒）
  ///
  /// 返回长度为 7 的列表，索引 0 = 6 天前，索引 6 = 今天。
  Future<List<int>> getWeeklyInputTimes({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final start = today.subtract(const Duration(days: 6));
    final records = await _afterWrites(() => _dao.getBetween(start, today));

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
    final record = await _afterWrites(() => _dao.getByDate(date));
    if (record == null) return 0;
    return _durationSeconds(
      record.outputTimeMilliseconds,
      record.outputTimeSeconds,
    );
  }

  /// 获取今日输出时间（秒）
  Future<int> getTodayOutputTime() => getOutputTime(DateTime.now());

  /// 获取过去 7 天每天的输出时间（秒）
  ///
  /// 返回长度为 7 的列表，索引 0 = 6 天前，索引 6 = 今天。
  Future<List<int>> getWeeklyOutputTimes({DateTime? now}) async {
    final today = _dateOnly(now ?? DateTime.now());
    final start = today.subtract(const Duration(days: 6));
    final records = await _afterWrites(() => _dao.getBetween(start, today));

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
    final records = await _afterWrites(
      () => _stageDao.getInDateRange(start, end),
    );
    final totals = <StudyStage, DailyStageStudyRecordData>{};
    for (final record in records) {
      final previous = totals[record.stage];
      totals[record.stage] = DailyStageStudyRecordData(
        stage: record.stage,
        studyTimeSeconds:
            (previous?.studyTimeSeconds ?? 0) +
            _durationSeconds(
              record.studyTimeMilliseconds,
              record.studyTimeSeconds,
            ),
        inputTimeSeconds:
            (previous?.inputTimeSeconds ?? 0) +
            _durationSeconds(
              record.inputTimeMilliseconds,
              record.inputTimeSeconds,
            ),
        outputTimeSeconds:
            (previous?.outputTimeSeconds ?? 0) +
            _durationSeconds(
              record.outputTimeMilliseconds,
              record.outputTimeSeconds,
            ),
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
    final records = await _afterWrites(() => _stageDao.getByDate(date));
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
    final record = await _afterWrites(() => _dao.getByDate(date));
    if (record == null) return null;
    return DailyTotalData(
      studyTimeSeconds: _durationSeconds(
        record.studyTimeMilliseconds,
        record.studyTimeSeconds,
      ),
      inputTimeSeconds: _durationSeconds(
        record.inputTimeMilliseconds,
        record.inputTimeSeconds,
      ),
      outputTimeSeconds: _durationSeconds(
        record.outputTimeMilliseconds,
        record.outputTimeSeconds,
      ),
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

final class _StudyWriteFailure {
  const _StudyWriteFailure(this.id, this.error, this.stackTrace);

  final int id;
  final Object error;
  final StackTrace stackTrace;
}
