import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/services/study_time_service.dart';
import 'package:echo_loop/models/study_stage.dart';

AppDatabase _createTestDb() {
  return AppDatabase(
    NativeDatabase.memory(
      setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
}

void main() {
  late AppDatabase db;
  late StudyTimeService service;

  setUp(() async {
    db = _createTestDb();
    service = StudyTimeService(
      db.dailyStudyRecordDao,
      db.dailyStageStudyRecordDao,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('StudyTimeService', () {
    test('阶段范围包含首尾日期、排除范围外记录并按阶段分别累加', () async {
      for (final day in [1, 2, 3, 4]) {
        await db.dailyStageStudyRecordDao.upsertAdd(
          DateTime(2026, 9, day),
          StudyStage.intensiveListen,
          studyTime: 61,
          inputTime: 20,
          outputTime: 10,
        );
      }
      await db.dailyStageStudyRecordDao.upsertAdd(
        DateTime(2026, 9, 3),
        StudyStage.savedVocabularyReview,
        studyTime: 180,
        inputTime: 30,
      );
      final rows = await service.getStageBreakdownInRange(
        DateTime(2026, 9, 2, 12),
        DateTime(2026, 9, 3, 23),
      );
      expect(rows.map((r) => r.stage), [
        StudyStage.intensiveListen,
        StudyStage.savedVocabularyReview,
      ]);
      expect(rows.map((r) => r.studyTimeSeconds), [122, 180]);
      expect(rows.map((r) => r.inputTimeSeconds), [40, 30]);
      expect(rows.map((r) => r.outputTimeSeconds), [20, 0]);
      expect(
        await service.getStageBreakdownInRange(
          DateTime(2025),
          DateTime(2025, 12, 31),
        ),
        isEmpty,
      );
    });

    test('日阶段明细使用累计毫秒精度与总量保持一致', () async {
      final date = DateTime(2026, 9, 8);
      for (var i = 0; i < 4; i += 1) {
        await service.addStudyDuration(
          const Duration(milliseconds: 45900),
          date: date,
          stage: StudyStage.freePlayer,
        );
        await service.addInputDuration(
          const Duration(milliseconds: 45900),
          date: date,
          stage: StudyStage.freePlayer,
        );
      }

      final stage = (await service.getStageBreakdown(date)).single;
      final total = await service.getDayTotal(date);

      expect(total, isNotNull);
      expect(stage.studyTimeSeconds, 183);
      expect(stage.inputTimeSeconds, 183);
      expect(stage.studyTimeSeconds, total?.studyTimeSeconds);
      expect(stage.inputTimeSeconds, total?.inputTimeSeconds);
    });

    test('首次调用 getTodayStudyTime 返回 0', () async {
      final result = await service.getTodayStudyTime();
      expect(result, 0);
    });

    test('addStudyTime 累加到今日 key', () async {
      await service.addStudyTime(30);
      expect(await service.getTodayStudyTime(), 30);

      await service.addStudyTime(45);
      expect(await service.getTodayStudyTime(), 75);
    });

    test('addStudyTime(0) 不改变已有值', () async {
      await service.addStudyTime(60);
      await service.addStudyTime(0);
      expect(await service.getTodayStudyTime(), 60);
    });

    test('负数被忽略', () async {
      await service.addStudyTime(60);
      await service.addStudyTime(-10);
      expect(await service.getTodayStudyTime(), 60);
    });

    test('自定义日期 key 读写正确', () async {
      final customDate = DateTime(2026, 1, 15);

      await service.addStudyTime(120, date: customDate);
      expect(await service.getStudyTime(customDate), 120);

      // 今日仍为 0
      expect(await service.getTodayStudyTime(), 0);
    });

    test('跨天时 key 自动切换', () async {
      final day1 = DateTime(2026, 3, 5);
      final day2 = DateTime(2026, 3, 6);

      await service.addStudyTime(100, date: day1);
      await service.addStudyTime(200, date: day2);

      expect(await service.getStudyTime(day1), 100);
      expect(await service.getStudyTime(day2), 200);
    });
  });

  group('StudyTimeService - streak', () {
    test('无学习记录时 streak 为 0', () async {
      final streak = await service.getStudyStreak(now: DateTime(2026, 3, 8));
      expect(streak, 0);
    });

    test('仅今天有记录时 streak 为 1', () async {
      final today = DateTime(2026, 3, 8);
      await service.addStudyTime(60, date: today);

      final streak = await service.getStudyStreak(now: today);
      expect(streak, 1);
    });

    test('连续 3 天学习 streak 为 3', () async {
      final today = DateTime(2026, 3, 8);
      await service.addStudyTime(60, date: DateTime(2026, 3, 6));
      await service.addStudyTime(60, date: DateTime(2026, 3, 7));
      await service.addStudyTime(60, date: today);

      final streak = await service.getStudyStreak(now: today);
      expect(streak, 3);
    });

    test('中间断一天则 streak 中断', () async {
      final today = DateTime(2026, 3, 8);
      await service.addStudyTime(60, date: DateTime(2026, 3, 5));
      // 3月6日无记录
      await service.addStudyTime(60, date: DateTime(2026, 3, 7));
      await service.addStudyTime(60, date: today);

      final streak = await service.getStudyStreak(now: today);
      expect(streak, 2); // 只有 7号+8号
    });

    test('今天无记录但昨天有则 streak 从昨天开始计', () async {
      final today = DateTime(2026, 3, 8);
      await service.addStudyTime(60, date: DateTime(2026, 3, 6));
      await service.addStudyTime(60, date: DateTime(2026, 3, 7));
      // 今天无记录

      final streak = await service.getStudyStreak(now: today);
      expect(streak, 2); // 6号+7号
    });
  });

  group('StudyTimeService - weeklyStudyTimes', () {
    test('无记录时返回全 0', () async {
      final times = await service.getWeeklyStudyTimes(
        now: DateTime(2026, 3, 8),
      );
      expect(times, [0, 0, 0, 0, 0, 0, 0]);
    });

    test('返回过去 7 天的正确数据', () async {
      final today = DateTime(2026, 3, 8); // Sunday
      await service.addStudyTime(100, date: DateTime(2026, 3, 2)); // Mon
      await service.addStudyTime(200, date: DateTime(2026, 3, 5)); // Thu
      await service.addStudyTime(300, date: today); // Sun

      final times = await service.getWeeklyStudyTimes(now: today);
      // [3/2, 3/3, 3/4, 3/5, 3/6, 3/7, 3/8]
      expect(times, [100, 0, 0, 200, 0, 0, 300]);
    });

    test('列表长度固定为 7', () async {
      final times = await service.getWeeklyStudyTimes(
        now: DateTime(2026, 3, 8),
      );
      expect(times.length, 7);
    });
  });

  group('StudyTimeService - weekTotalStudyTime', () {
    test('无记录时返回 0', () async {
      final total = await service.getWeekTotalStudyTime(
        now: DateTime(2026, 3, 8),
      );
      expect(total, 0);
    });

    test('累加本周一至今的学习时长', () async {
      // 2026-3-8 是周日，本周一是 3-2
      final today = DateTime(2026, 3, 8);
      await service.addStudyTime(100, date: DateTime(2026, 3, 2)); // Mon
      await service.addStudyTime(200, date: DateTime(2026, 3, 4)); // Wed
      await service.addStudyTime(300, date: today); // Sun
      // 上周日 3-1 不计入
      await service.addStudyTime(999, date: DateTime(2026, 3, 1));

      final total = await service.getWeekTotalStudyTime(now: today);
      expect(total, 600); // 100+200+300
    });

    test('周一时只计当天', () async {
      final monday = DateTime(2026, 3, 2); // Monday
      await service.addStudyTime(150, date: monday);
      // 上周日不计入
      await service.addStudyTime(999, date: DateTime(2026, 3, 1));

      final total = await service.getWeekTotalStudyTime(now: monday);
      expect(total, 150);
    });
  });

  group('StudyTimeService - inputWords', () {
    test('首次读取返回 0', () async {
      expect(await service.getTodayInputWords(), 0);
    });

    test('addInputWords 累加', () async {
      await service.addInputWords(50);
      expect(await service.getTodayInputWords(), 50);

      await service.addInputWords(30);
      expect(await service.getTodayInputWords(), 80);
    });

    test('count <= 0 时忽略', () async {
      await service.addInputWords(100);
      await service.addInputWords(0);
      await service.addInputWords(-5);
      expect(await service.getTodayInputWords(), 100);
    });

    test('自定义日期隔离', () async {
      final day1 = DateTime(2026, 3, 5);
      final day2 = DateTime(2026, 3, 6);

      await service.addInputWords(100, date: day1);
      await service.addInputWords(200, date: day2);

      expect(await service.getInputWords(day1), 100);
      expect(await service.getInputWords(day2), 200);
    });
  });

  group('StudyTimeService - outputWords', () {
    test('首次读取返回 0', () async {
      expect(await service.getTodayOutputWords(), 0);
    });

    test('addOutputWords 累加', () async {
      await service.addOutputWords(40);
      expect(await service.getTodayOutputWords(), 40);

      await service.addOutputWords(60);
      expect(await service.getTodayOutputWords(), 100);
    });

    test('count <= 0 时忽略', () async {
      await service.addOutputWords(50);
      await service.addOutputWords(0);
      await service.addOutputWords(-1);
      expect(await service.getTodayOutputWords(), 50);
    });

    test('输入与输出互不干扰', () async {
      await service.addInputWords(100);
      await service.addOutputWords(50);

      expect(await service.getTodayInputWords(), 100);
      expect(await service.getTodayOutputWords(), 50);
    });
  });

  group('StudyTimeService - inputTime', () {
    test('首次读取返回 0', () async {
      expect(await service.getTodayInputTime(), 0);
    });

    test('addInputTime 累加', () async {
      await service.addInputTime(30);
      expect(await service.getTodayInputTime(), 30);

      await service.addInputTime(45);
      expect(await service.getTodayInputTime(), 75);
    });

    test('seconds <= 0 时忽略', () async {
      await service.addInputTime(60);
      await service.addInputTime(0);
      await service.addInputTime(-5);
      expect(await service.getTodayInputTime(), 60);
    });

    test('自定义日期隔离', () async {
      final day1 = DateTime(2026, 3, 5);
      final day2 = DateTime(2026, 3, 6);

      await service.addInputTime(100, date: day1);
      await service.addInputTime(200, date: day2);

      expect(await service.getInputTime(day1), 100);
      expect(await service.getInputTime(day2), 200);
    });

    test('getWeeklyInputTimes 返回过去 7 天数据', () async {
      final today = DateTime(2026, 3, 8);
      await service.addInputTime(100, date: DateTime(2026, 3, 2));
      await service.addInputTime(200, date: DateTime(2026, 3, 5));
      await service.addInputTime(300, date: today);

      final times = await service.getWeeklyInputTimes(now: today);
      expect(times, [100, 0, 0, 200, 0, 0, 300]);
      expect(times.length, 7);
    });
  });

  group('StudyTimeService - outputTime', () {
    test('首次读取返回 0', () async {
      expect(await service.getTodayOutputTime(), 0);
    });

    test('addOutputTime 累加', () async {
      await service.addOutputTime(20);
      expect(await service.getTodayOutputTime(), 20);

      await service.addOutputTime(30);
      expect(await service.getTodayOutputTime(), 50);
    });

    test('seconds <= 0 时忽略', () async {
      await service.addOutputTime(40);
      await service.addOutputTime(0);
      await service.addOutputTime(-1);
      expect(await service.getTodayOutputTime(), 40);
    });

    test('getWeeklyOutputTimes 返回过去 7 天数据', () async {
      final today = DateTime(2026, 3, 8);
      await service.addOutputTime(50, date: DateTime(2026, 3, 3));
      await service.addOutputTime(80, date: today);

      final times = await service.getWeeklyOutputTimes(now: today);
      expect(times, [0, 50, 0, 0, 0, 0, 80]);
      expect(times.length, 7);
    });

    test('输入时间与输出时间互不干扰', () async {
      await service.addInputTime(100);
      await service.addOutputTime(50);

      expect(await service.getTodayInputTime(), 100);
      expect(await service.getTodayOutputTime(), 50);
    });
  });
}
