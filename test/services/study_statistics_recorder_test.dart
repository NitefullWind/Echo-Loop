import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/services/study_statistics_recorder.dart';
import 'package:echo_loop/services/study_time_service.dart';
import 'package:echo_loop/services/study_activity_gate.dart';
import 'package:echo_loop/services/learned_vocabulary_tracker.dart';
import 'package:echo_loop/models/study_stage.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late StudyStatisticsRecorder recorder;
  late StudyActivityGate activityGate;
  late LearnedVocabularyTracker vocabularyTracker;
  var vocabularyPersisted = false;

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    db = AppDatabase(NativeDatabase.memory());
    activityGate = StudyActivityGate();
    vocabularyPersisted = false;
    vocabularyTracker = LearnedVocabularyTracker(
      persistWordForms: (wordForms) async {
        vocabularyPersisted = wordForms.isNotEmpty;
      },
      onStatsUpdated: () {},
      flushDelay: Duration.zero,
    );
    recorder = StudyStatisticsRecorder(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
      activityGate: activityGate,
      vocabularyTracker: vocabularyTracker,
    );
  });

  tearDown(() async {
    await vocabularyTracker.dispose();
    activityGate.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await db.close();
  });

  test('保留亚秒播放时长并记录听到的词数', () async {
    await recorder.recordSentencePlayback(
      duration: const Duration(milliseconds: 700),
      heardWordCount: 1,
      text: 'short',
      stage: StudyStage.intensiveListen,
    );
    await recorder.recordVocabularyPlayback(
      duration: const Duration(milliseconds: 300),
      stage: StudyStage.intensiveListen,
    );

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    final stage = (await db.dailyStageStudyRecordDao.getByDate(
      DateTime.now(),
    )).single;
    expect(record?.inputTimeMilliseconds, 1000);
    expect(record?.inputTimeSeconds, 0);
    expect(record?.inputWords, 2);
    expect(stage.inputTimeMilliseconds, 1000);
  });

  test('录音识别记录亚秒输出时长和输出词数', () async {
    await recorder.recordSpeechRecognition(
      duration: const Duration(milliseconds: 450),
      producedWordCount: 3,
      stage: StudyStage.retell,
    );

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record?.outputTimeMilliseconds, 450);
    expect(record?.outputWords, 3);
  });

  test('可只记录按句播放词数而跳过输入时长', () async {
    await recorder.recordSentencePlayback(
      duration: const Duration(seconds: 2),
      heardWordCount: 2,
      text: 'free player sentence',
      stage: StudyStage.freePlayer,
      recordInputDuration: false,
    );

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record?.inputTimeMilliseconds, 0);
    expect(record?.inputWords, 2);
  });

  test('后台完成按句播放时不写入时长、词数或词汇', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    await recorder.recordSentencePlayback(
      duration: const Duration(seconds: 2),
      heardWordCount: 2,
      text: 'background sentence',
      stage: StudyStage.freePlayer,
    );

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record, isNull);
    await vocabularyTracker.flush();
    expect(vocabularyPersisted, isFalse);
  });

  test('后台录音识别和主动学习时长均不写入统计', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    await recorder.recordSpeechRecognition(
      duration: const Duration(seconds: 2),
      producedWordCount: 3,
      stage: StudyStage.retell,
    );
    await recorder.recordActiveDuration(
      const Duration(seconds: 2),
      stage: StudyStage.retell,
    );

    final record = await db.dailyStudyRecordDao.getByDate(DateTime.now());
    expect(record, isNull);
  });
}
