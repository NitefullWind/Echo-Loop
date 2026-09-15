import '../../models/sentence.dart';
import '../../models/sentence_playback_result.dart';
import '../audio_engine/audio_engine_provider.dart';
import '../audio_engine/foreground_audio_engine_provider.dart';
import '../media_engine/media_engine_provider.dart';
import '../../services/app_logger.dart';

/// 句子级学习任务依赖的最小播放契约。
///
/// 学习状态机只描述“播放一句”，不关心底层是 just_audio 还是 media_kit。
/// 音频适配器继续委托原引擎，视频适配器复用同一 MediaEngine。
abstract interface class SentencePlaybackDriver {
  int newSession();
  bool isActiveSession(int sessionId);

  /// 立即使当前播放失效并暂停底层引擎，迟到回调不得继续推进业务状态。
  Future<void> invalidateSession();

  Future<void> pause();
  Future<void> setSpeed(double speed);
  Future<SentencePlaybackResult> playSentence(Sentence sentence, int sessionId);

  /// 按指定速度完整播放一句；MediaEngine 实现自行管理底层播放请求。
  Future<SentencePlaybackResult> playSentenceWithSpeed(
    Sentence sentence,
    double speed,
  );

  /// 绑定系统媒体控制；不提供系统媒体会话的前台音频适配器实现为空操作。
  void bindLockScreen({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  });
  void setSessionActive(bool active);
  void setProgressFrozen(bool frozen);
  void unbindLockScreen();
}

/// 逐句精听在句子播放之外还需要意群区间播放。
abstract interface class IntensiveListenPlaybackDriver
    implements SentencePlaybackDriver {
  Future<SentencePlaybackResult> playRangeOnce(
    Duration start,
    Duration end,
    int sessionId,
  );
}

/// 难句跟读原音频适配器；所有调用仍委托前台 just_audio 引擎。
class ForegroundSentencePlaybackDriver implements SentencePlaybackDriver {
  ForegroundSentencePlaybackDriver(this._engine);

  final ForegroundAudioEngine _engine;

  @override
  int newSession() => _engine.newSession();

  @override
  bool isActiveSession(int sessionId) => _engine.isActiveSession(sessionId);

  @override
  Future<void> invalidateSession() async {
    _engine.newSession();
    await _engine.pause();
  }

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> setSpeed(double speed) => _engine.setSpeed(speed);

  @override
  Future<SentencePlaybackResult> playSentence(
    Sentence sentence,
    int sessionId,
  ) async {
    await _engine.playClipOnce(sentence, sessionId);
    return _engine.isActiveSession(sessionId)
        ? SentencePlaybackResult.completed
        : SentencePlaybackResult.cancelled;
  }

  @override
  Future<SentencePlaybackResult> playSentenceWithSpeed(
    Sentence sentence,
    double speed,
  ) async {
    await setSpeed(speed);
    return playSentence(sentence, newSession());
  }

  @override
  void bindLockScreen({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void setSessionActive(bool active) {}

  @override
  void setProgressFrozen(bool frozen) {}

  @override
  void unbindLockScreen() {}
}

/// 原音频逐句精听适配器；所有调用仍原样委托给 AudioEngine。
class AudioIntensiveListenPlaybackDriver
    implements IntensiveListenPlaybackDriver {
  AudioIntensiveListenPlaybackDriver(this._engine);

  final AudioEngine _engine;

  @override
  int newSession() => _engine.newSession();

  @override
  bool isActiveSession(int sessionId) => _engine.isActiveSession(sessionId);

  @override
  Future<void> invalidateSession() async {
    _engine.newSession();
    await _engine.pause();
  }

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> setSpeed(double speed) => _engine.setSpeed(speed);

  @override
  Future<SentencePlaybackResult> playSentence(
    Sentence sentence,
    int sessionId,
  ) async {
    await _engine.playClipOnce(sentence, sessionId);
    return _engine.isActiveSession(sessionId)
        ? SentencePlaybackResult.completed
        : SentencePlaybackResult.cancelled;
  }

  @override
  Future<SentencePlaybackResult> playSentenceWithSpeed(
    Sentence sentence,
    double speed,
  ) async {
    await setSpeed(speed);
    return playSentence(sentence, newSession());
  }

  @override
  Future<SentencePlaybackResult> playRangeOnce(
    Duration start,
    Duration end,
    int sessionId,
  ) async {
    await _engine.playRangeOnce(start, end, sessionId);
    return _engine.isActiveSession(sessionId)
        ? SentencePlaybackResult.completed
        : SentencePlaybackResult.cancelled;
  }

  @override
  void bindLockScreen({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _engine.setTransportHandlers(onPlay: onPlay, onPause: onPause);
    _engine.setSkipHandlers(onPrevious: onPrevious, onNext: onNext);
    _engine.setSeekHandlers(onRewind: null, onFastForward: null);
  }

  @override
  void setSessionActive(bool active) {
    _engine.setLogicalPlaying(active);
    if (active) {
      _engine.startKeepAlive();
    } else {
      _engine.stopKeepAlive();
    }
  }

  @override
  void setProgressFrozen(bool frozen) => _engine.setProgressFrozen(frozen);

  @override
  void unbindLockScreen() {
    _engine.setTransportHandlers(onPlay: null, onPause: null);
    _engine.setSkipHandlers(onPrevious: null, onNext: null);
    _engine.setSeekHandlers(onRewind: null, onFastForward: null);
    _engine.setLogicalPlaying(null);
    _engine.setProgressFrozen(false);
    _engine.stopKeepAlive();
  }
}

/// 学习任务共享的媒体句子播放驱动；只操作 MediaEngine，不接管音频链路。
class MediaSentencePlaybackDriver implements IntensiveListenPlaybackDriver {
  MediaSentencePlaybackDriver(this._engine);

  final MediaEngine _engine;
  double _playbackSpeed = 1.0;

  @override
  int newSession() => _engine.newSession();

  @override
  bool isActiveSession(int sessionId) => _engine.isActiveSession(sessionId);

  @override
  Future<void> invalidateSession() =>
      _engine.cancelActiveRange(reason: 'driver-invalidate');

  @override
  Future<void> pause() => _engine.cancelActiveRange(reason: 'driver-pause');

  @override
  Future<void> setSpeed(double speed) async {
    _playbackSpeed = speed;
  }

  @override
  Future<SentencePlaybackResult> playSentenceWithSpeed(
    Sentence sentence,
    double speed,
  ) => _playSentenceWithDiagnostics(sentence, speed);

  @override
  Future<SentencePlaybackResult> playSentence(
    Sentence sentence,
    int sessionId,
  ) => _engine.playRange(
    sentence.startTime,
    sentence.endTime,
    speed: _playbackSpeed,
    sessionId: sessionId,
  );

  Future<SentencePlaybackResult> _playSentenceWithDiagnostics(
    Sentence sentence,
    double speed,
  ) async {
    AppLogger.log(
      'SentencePlaybackDriver',
      'start: sentence=${sentence.index} '
          'range=${sentence.startTime.inMilliseconds}-'
          '${sentence.endTime.inMilliseconds}ms',
    );
    final result = await _engine.playRange(
      sentence.startTime,
      sentence.endTime,
      speed: speed,
      sessionId: _engine.currentSessionId,
    );
    AppLogger.log(
      'SentencePlaybackDriver',
      'return: sentence=${sentence.index} '
          'position=${_engine.currentPosition.inMilliseconds}ms result=$result',
    );
    return result;
  }

  @override
  Future<SentencePlaybackResult> playRangeOnce(
    Duration start,
    Duration end,
    int sessionId,
  ) => _engine.playRange(
    start,
    end,
    speed: _playbackSpeed,
    sessionId: sessionId,
  );

  @override
  void bindLockScreen({
    required Future<void> Function() onPlay,
    required Future<void> Function() onPause,
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _engine.setTransportHandlers(onPlay: onPlay, onPause: onPause);
    _engine.setSkipHandlers(onPrevious: onPrevious, onNext: onNext);
  }

  @override
  void setSessionActive(bool active) {
    _engine.setLogicalPlaying(active);
    if (active) {
      _engine.startKeepAlive();
    } else {
      _engine.stopKeepAlive();
    }
  }

  @override
  void setProgressFrozen(bool frozen) => _engine.setProgressFrozen(frozen);

  @override
  void unbindLockScreen() {
    _engine.setTransportHandlers(onPlay: null, onPause: null);
    _engine.setSkipHandlers(onPrevious: null, onNext: null);
    _engine.setLogicalPlaying(null);
    _engine.setProgressFrozen(false);
    _engine.stopKeepAlive();
  }
}

/// 旧名称兼容层；媒体句子驱动已供多个学习任务共享。
typedef MediaIntensiveListenPlaybackDriver = MediaSentencePlaybackDriver;
