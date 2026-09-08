import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/models/study_stage.dart';
import 'package:echo_loop/services/study_activity_gate.dart';
import 'package:echo_loop/services/study_session_timer.dart';
import 'package:echo_loop/services/study_time_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late StudyActivityGate activityGate;

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    db = AppDatabase(NativeDatabase.memory());
    activityGate = StudyActivityGate();
  });

  tearDown(() async {
    activityGate.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await db.close();
  });

  test('stop persists foreground duration under the requested stage', () async {
    final timer = StudySessionTimer(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
      stage: StudyStage.savedSentencesReview,
      activityGate: activityGate,
    );

    timer.start();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await timer.stop();

    final records = await db.dailyStageStudyRecordDao.getByDate(DateTime.now());
    final record = records.singleWhere(
      (item) => item.stage == StudyStage.savedSentencesReview,
    );
    expect(record.studyTimeSeconds, greaterThanOrEqualTo(1));
    await timer.dispose();
  });

  test('可选地将前台播放时长同步记为输入时长', () async {
    final timer = StudySessionTimer(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
      stage: StudyStage.freePlayer,
      activityGate: activityGate,
      recordInputDuration: true,
    );

    timer.start();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await timer.stop();

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record?.studyTimeMilliseconds, greaterThanOrEqualTo(1000));
    expect(record?.inputTimeMilliseconds, record?.studyTimeMilliseconds);
    await timer.dispose();
  });

  test('后台启动时不计时，回到前台后才开始计时', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    final timer = StudySessionTimer(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
      stage: StudyStage.freePlayer,
      activityGate: activityGate,
    );

    timer.start();
    expect(timer.elapsed, Duration.zero);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await timer.stop();

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record?.studyTimeMilliseconds, greaterThanOrEqualTo(1000));
    await timer.dispose();
  });

  test('切到后台暂停计时，回到前台后恢复计时', () async {
    final timer = StudySessionTimer(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
      stage: StudyStage.freePlayer,
      activityGate: activityGate,
    );

    timer.start();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final elapsedInForeground = timer.elapsed;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(timer.elapsed, elapsedInForeground);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(timer.elapsed, greaterThan(elapsedInForeground));

    await timer.stop();
    await timer.dispose();
  });

  test('手动暂停后切回前台不会自动恢复，显式 resume 后才继续计时', () async {
    final timer = StudySessionTimer(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
      stage: StudyStage.freePlayer,
      activityGate: activityGate,
    );

    timer.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await timer.pause();
    final elapsedWhilePaused = timer.elapsed;

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(timer.elapsed, elapsedWhilePaused);

    timer.resume();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(timer.elapsed, greaterThan(elapsedWhilePaused));

    await timer.dispose();
  });
}
