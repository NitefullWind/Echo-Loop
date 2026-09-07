import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/services/study_statistics_recorder.dart';
import 'package:echo_loop/services/study_time_service.dart';
import 'package:echo_loop/models/study_stage.dart';

void main() {
  late AppDatabase db;
  late StudyStatisticsRecorder recorder;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    recorder = StudyStatisticsRecorder(
      studyTimeService: StudyTimeService(
        db.dailyStudyRecordDao,
        db.dailyStageStudyRecordDao,
      ),
    );
  });

  tearDown(() => db.close());

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
    final stage = (await db.dailyStageStudyRecordDao.getByDate(DateTime.now()))
        .single;
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
}
