/// 跟读流程引擎
///
/// 封装跟读核心流程：play → record → evaluate → interval → next repeat/sentence。
/// 纯 Dart 类，不依赖 Riverpod，通过回调与外部交互。
///
/// 各页面的 Controller/Provider 组合此引擎：
/// - 跟读页面：ListenAndRepeatController
/// - 难句补练：ReviewDifficultPractice（跟读模式时使用）
/// - 收藏复习：BookmarkReview（跟读模式时使用）
library;

import 'dart:async';
import 'dart:io';

import '../../models/sentence.dart';
import '../../models/sentence_playback_result.dart';
import '../../services/app_logger.dart';
import '../../services/audio_playback_service.dart';
import '../learning_session/countdown_controller.dart';
import 'repeat_flow_phase.dart';
import 'repeat_flow_state.dart';

/// 智能停顿最小时长（毫秒）
const kSmartPauseMinMs = 2000;

/// 智能停顿最大时长（毫秒）
const kSmartPauseMaxMs = 20000;

/// 倍率停顿最小时长（毫秒）
const kMultiplierPauseMinMs = 1000;

/// 倒计时快进速度倍率

/// 录音最大时长 = sentenceDuration × 此倍率 + kRecordingTimeoutBase
const kRecordingDurationMultiplier = 2.5;

/// 录音超时基础时长
const kRecordingTimeoutBase = Duration(seconds: 5);

/// 录音最小超时时长
const kRecordingMinTimeout = Duration(seconds: 10);

/// 跟读流程配置
class RepeatFlowConfig {
  /// 音频项 ID（用于构建 promptId）
  final String audioItemId;

  /// 获取指定句子的目标遍数
  final int Function(Sentence sentence) getRepeatCount;

  /// 获取遍间倒计时时长
  final Duration Function(Sentence sentence) getIntervalDuration;

  /// 是否手动模式
  final bool Function() isManualMode;

  /// 句子播放前的钩子（如收藏复习需要跨音频加载）
  final Future<void> Function(int sentenceIndex)? onBeforeSentenceStart;

  /// 句子播完一遍的回调（用于学习统计等）
  final void Function(Sentence sentence)? onSentencePlayed;

  /// promptId 前缀（默认 'lar'，各页面可自定义）
  final String promptIdPrefix;

  const RepeatFlowConfig({
    required this.audioItemId,
    required this.getRepeatCount,
    required this.getIntervalDuration,
    required this.isManualMode,
    this.onBeforeSentenceStart,
    this.onSentencePlayed,
    this.promptIdPrefix = 'lar',
  });
}

/// 跟读流程引擎回调
class RepeatFlowCallbacks {
  /// 暂停音频播放（enterWaitingForUser 时调用）
  final void Function() pauseAudio;

  /// 播放句子音频
  final Future<SentencePlaybackResult> Function(
    Sentence sentence,
    int flowToken,
  )
  playSentence;

  /// 开始录音
  final void Function({
    required String promptId,
    required String referenceText,
    required Duration maxDuration,
    Duration? referenceDuration,
  })
  startRecording;

  /// 取消录音
  final Future<void> Function() cancelRecording;

  /// 停止录音并评估
  final Future<void> Function({required String referenceText}) stopAndEvaluate;

  /// 清除录音数据（切句/重播时调用），返回值用于等待麦克风真正释放。
  final FutureOr<void> Function() clearRecording;

  /// 设置录音最大时长
  final void Function(Duration duration) setMaxRecordingDuration;

  /// 查询是否检测到语音
  final bool Function() hasDetectedSpeech;

  const RepeatFlowCallbacks({
    required this.pauseAudio,
    required this.playSentence,
    required this.startRecording,
    required this.cancelRecording,
    required this.stopAndEvaluate,
    required this.clearRecording,
    required this.setMaxRecordingDuration,
    required this.hasDetectedSpeech,
  });
}

/// 跟读流程引擎
///
/// 通过 [prepare] 配置句子和参数，[startPlaying] 开始流程。
/// 状态变化通过 [onStateChanged] 回调通知外部。
class RepeatFlowEngine {
  /// 状态变化回调
  final void Function(RepeatFlowState state) onStateChanged;

  /// 外部交互回调
  final RepeatFlowCallbacks callbacks;

  /// 日志标签
  final String logTag;

  /// 倒计时控制器
  final CountdownController _countdown = CountdownController();

  /// 录音回放服务
  final AudioPlaybackService _playbackService = AudioPlaybackService();

  /// 句子列表
  List<Sentence> _sentences = [];

  /// 配置
  late RepeatFlowConfig _config;

  /// 当前状态
  RepeatFlowState _state = const RepeatFlowState();

  /// 当前原句播放完成后是否转入等待用户状态。
  bool _waitAfterCurrentPrompt = false;

  /// 用户停止过当前句的自动倒计时；切到下一句前不再自动启动遍间等待。
  bool _userTookOverCurrentSentence = false;

  RepeatFlowEngine({
    required this.onStateChanged,
    required this.callbacks,
    this.logTag = 'RepeatFlow',
  });

  /// 当前状态（只读）
  RepeatFlowState get state => _state;

  /// 当前原句播完后是否会进入等待态。
  bool get willEnterWaitingAfterCurrentPrompt => _waitAfterCurrentPrompt;

  /// 当前句子
  Sentence? get currentSentence =>
      _sentences.isNotEmpty && _state.sentenceIndex < _sentences.length
      ? _sentences[_state.sentenceIndex]
      : null;

  /// 当前 promptId
  String get currentPromptId {
    final sentence = currentSentence;
    final idx = sentence?.index ?? _state.sentenceIndex;
    return '${_config.promptIdPrefix}:${_config.audioItemId}:$idx';
  }

  /// 当前配置
  RepeatFlowConfig get config => _config;

  /// 句子列表（只读）
  List<Sentence> get sentences => List.unmodifiable(_sentences);

  // ========== 公开方法 ==========

  /// 准备会话数据
  void prepare({
    required List<Sentence> sentences,
    required RepeatFlowConfig config,
    int startIndex = 0,
  }) {
    _sentences = sentences.map((s) => s.copyWith()).toList();
    _config = config;

    final safeIndex = _sentences.isEmpty
        ? 0
        : startIndex.clamp(0, _sentences.length - 1);
    final sentence = _sentences.isNotEmpty ? _sentences[safeIndex] : null;

    _updateState(
      RepeatFlowState(
        phase: const Idle(),
        sentenceIndex: safeIndex,
        totalSentences: _sentences.length,
        totalRepeats: sentence != null ? config.getRepeatCount(sentence) : 1,
        intervalDuration: sentence != null
            ? config.getIntervalDuration(sentence)
            : Duration.zero,
        isReviewPlaybackActive: false,
        flowToken: 1,
      ),
    );
  }

  /// 开始播放
  Future<void> startPlaying() async {
    if (_sentences.isEmpty) return;
    await _playCurrentSentence();
  }

  /// 进入等待用户操作状态。
  ///
  /// 完成弹窗展示前也允许从 [SessionCompleted] 接管，保留末句的练习交互界面。
  void enterWaitingForUser({bool afterCurrentPrompt = false}) {
    final phase = _state.phase;
    if (phase is WaitingForUser || phase is Idle) {
      return;
    }

    if (afterCurrentPrompt && phase is PlayingPrompt) {
      _waitAfterCurrentPrompt = true;
      AppLogger.log(logTag, '→ WaitingForUser (当前句播完后)');
      return;
    }

    if (phase is WaitingInterval) {
      _userTookOverCurrentSentence = true;
      _state = _state.copyWith(flowToken: _state.flowToken + 1);
    }

    _stopActiveResources();
    _waitAfterCurrentPrompt = false;
    _updateState(
      _state.copyWith(
        phase: const WaitingForUser(WaitingReason.userInteraction),
      ),
    );
    AppLogger.log(logTag, '→ WaitingForUser (从 ${phase.runtimeType})');
  }

  /// 用户交互（查词/翻译等）
  ///
  /// 仅自动模式生效。手动模式下不打断。
  void onUserInteraction() {
    if (_config.isManualMode()) return;
    enterWaitingForUser(afterCurrentPrompt: true);
  }

  /// 下一句
  Future<void> nextSentence() async {
    if (_state.isLastSentence) return;
    await _jumpToSentence(_state.sentenceIndex + 1);
  }

  /// 上一句
  Future<void> previousSentence() async {
    if (_state.isFirstSentence) return;
    await _jumpToSentence(_state.sentenceIndex - 1);
  }

  /// 跳转到指定句子（0-based）。
  ///
  /// 供进度条拖动跳转使用：越界自动 clamp，目标与当前相同时直接返回。
  Future<void> goToSentence(int index) async {
    if (_sentences.isEmpty) return;
    final target = index.clamp(0, _sentences.length - 1);
    if (target == _state.sentenceIndex) return;
    await _jumpToSentence(target);
  }

  /// 录音按钮点击
  Future<void> onRecordButtonTapped() async {
    final phase = _state.phase;
    if (phase is Recording) {
      await stopRecording();
      return;
    }
    if (_state.isReviewPlaybackActive) {
      await stopPlayback();
    }
    startManualRecording();
  }

  /// 录音回放按钮点击
  Future<void> togglePlayback() async {
    if (_state.isReviewPlaybackActive) {
      await stopPlayback();
    } else {
      await playRecording();
    }
  }

  /// 为播放录音回放做准备。
  ///
  /// Badge 组件会自行管理录音回放和图标切换；
  /// 这里仅负责清理流程状态，例如取消倒计时并进入 WaitingForUser。
  void prepareForPlayback() {
    final phase = _state.phase;
    if (phase is WaitingInterval) {
      _countdown.cancel();
    }
    _updateState(
      _state.copyWith(
        phase: const WaitingForUser(WaitingReason.userInteraction),
        isReviewPlaybackActive: false,
      ),
    );
  }

  /// 手动开始录音
  void startManualRecording() {
    final phase = _state.phase;
    if (phase is! WaitingInterval && phase is! WaitingForUser) {
      AppLogger.log(
        logTag,
        'startManualRecording 跳过: phase=${phase.runtimeType}',
      );
      return;
    }
    _startRecording();
  }

  /// 手动停止录音
  Future<void> stopRecording() async {
    if (_state.phase is! Recording) return;
    final sentence = currentSentence;
    if (sentence == null) return;

    // iOS 上无语音时走快速取消（避免等 finalTranscriptReady 超时）。
    // Android 上始终走评估（VAD 可能不工作，但录音文件有效，显示"录音"badge）。
    if (!callbacks.hasDetectedSpeech() && !Platform.isAndroid) {
      AppLogger.log(logTag, '手动停止录音: 无语音 → 取消');
      await callbacks.cancelRecording();
      _updateState(
        _state.copyWith(
          phase: const WaitingForUser(WaitingReason.recordingFailed),
        ),
      );
      return;
    }

    AppLogger.log(logTag, '手动停止录音 → 评估');
    await callbacks.stopAndEvaluate(referenceText: sentence.text);
  }

  /// 播放录音回放
  Future<void> playRecording() async {
    final path = _state.recordingPath;
    if (path == null || path.isEmpty) return;

    final phase = _state.phase;
    if (phase is! WaitingInterval &&
        phase is! WaitingForUser &&
        phase is! Idle) {
      return;
    }

    if (phase is WaitingInterval) {
      _countdown.cancel();
    }

    _updateState(
      _state.copyWith(
        phase: const WaitingForUser(WaitingReason.userInteraction),
        isReviewPlaybackActive: true,
      ),
    );
    final token = _state.flowToken;
    AppLogger.log(logTag, '播放录音回放: $path');

    await _playbackService.play(path);

    if (token != _state.flowToken) return;
    if (!_state.isReviewPlaybackActive) return;
    _onReviewPlaybackFinished();
  }

  /// 停止录音回放
  Future<void> stopPlayback() async {
    if (!_state.isReviewPlaybackActive) return;
    await _playbackService.stop();
    _onReviewPlaybackFinished();
  }

  /// 快进倒计时（动态速度，~1.5 秒内结束）
  void fastForwardInterval() {
    final phase = _state.phase;
    if (phase is! WaitingInterval) return;
    if (!_countdown.isActive) return;
    final speed = _countdown.fastForward();
    _updateState(_state.copyWith(phase: phase.copyWith(speed: speed)));
    AppLogger.log(logTag, '倒计时快进 ${speed.toStringAsFixed(1)}x');
  }

  /// 暂停倒计时
  void pauseInterval() {
    final phase = _state.phase;
    if (phase is! WaitingInterval) return;
    if (_countdown.isPaused) return;
    _countdown.pause();
    _updateState(_state.copyWith(phase: phase.copyWith(isPaused: true)));
  }

  /// 恢复倒计时
  void resumeInterval() {
    final phase = _state.phase;
    if (phase is! WaitingInterval) return;
    if (!_countdown.isPaused) return;
    _countdown.resume();
    _updateState(_state.copyWith(phase: phase.copyWith(isPaused: false)));
  }

  /// 重播当前句子
  ///
  /// 用户主动按"再来一遍"，`repeatIndex` 同步 +1（不封顶，允许 4/3 这种 overshoot 显示）。
  Future<void> replayCurrentSentence() async {
    _waitAfterCurrentPrompt = false;
    _atomicReset();
    final flowToken = _state.flowToken;
    await callbacks.clearRecording();
    if (flowToken != _state.flowToken) return;
    _updateState(
      _state.copyWith(
        repeatIndex: _state.repeatIndex + 1,
        recordingPath: null,
        recordingScore: null,
        isReviewPlaybackActive: false,
        flowToken: flowToken,
      ),
    );
    await _playCurrentSentence();
  }

  /// 重新开始当前句子（设置变更后调用，从第一遍开始）
  ///
  /// 当 [autoplay] 为 false 时，仅刷新当前句配置并停留在等待态，
  /// 不会立刻离开设置前的 WaitingForUser 状态。
  Future<void> restartCurrentSentence({bool autoplay = true}) async {
    final sentence = currentSentence;
    if (sentence == null) return;

    _waitAfterCurrentPrompt = false;
    _atomicReset();
    final flowToken = _state.flowToken;
    await callbacks.clearRecording();
    if (flowToken != _state.flowToken) return;

    final nextPhase = autoplay
        ? const Idle()
        : const WaitingForUser(WaitingReason.userInteraction);

    _updateState(
      _state.copyWith(
        phase: nextPhase,
        repeatIndex: 0,
        totalRepeats: _config.getRepeatCount(sentence),
        intervalDuration: _config.getIntervalDuration(sentence),
        recordingPath: null,
        recordingScore: null,
        isReviewPlaybackActive: false,
        flowToken: flowToken,
      ),
    );

    if (autoplay) {
      await _playCurrentSentence();
    }
  }

  /// 停止会话
  void stopSession() {
    _waitAfterCurrentPrompt = false;
    _atomicReset();
    _updateState(
      _state.copyWith(phase: const Idle(), isReviewPlaybackActive: false),
    );
  }

  /// 录音完成回调（由外部 Provider 的 ref.listen 桥接调用）。
  ///
  /// 评分是可选附加信息：关闭评分时仍应保留有效录音并继续训练流程，
  /// 只有没有可回放录音文件时才视为录音失败。
  void onRecordingFinished(String? filePath, double? score) {
    if (_state.phase is! Recording) return;

    final hasRecording = filePath != null && filePath.isNotEmpty;
    AppLogger.log(
      logTag,
      score != null
          ? '录音评估完成: score=$score'
          : hasRecording
          ? '录音完成: 未评分，保留录音'
          : '录音失败: 无有效录音文件',
    );
    _updateState(
      _state.copyWith(
        recordingPath: filePath,
        recordingScore: score,
        isReviewPlaybackActive: false,
      ),
    );

    if (!hasRecording) {
      AppLogger.log(logTag, '→ 无有效录音，等待用户重试');
      _updateState(
        _state.copyWith(
          phase: const WaitingForUser(WaitingReason.recordingFailed),
          recordingPath: null,
          recordingScore: null,
          isReviewPlaybackActive: false,
        ),
      );
      unawaited(Future<void>.sync(callbacks.clearRecording));
      return;
    }

    if (_config.isManualMode()) {
      AppLogger.log(logTag, '→ 手动模式，等待用户操作');
      _updateState(
        _state.copyWith(
          phase: const WaitingForUser(WaitingReason.userInteraction),
        ),
      );
      return;
    }

    if (_userTookOverCurrentSentence) {
      AppLogger.log(logTag, '→ 用户已接管当前句，评估后保持等待');
      _updateState(
        _state.copyWith(
          phase: const WaitingForUser(WaitingReason.userInteraction),
        ),
      );
      return;
    }

    _startInterval(resetFull: true);
  }

  /// 录音取消/超时回调（由外部 Provider 的 ref.listen 桥接调用）
  void onRecordingCancelled() {
    if (_state.phase is! Recording) return;
    AppLogger.log(logTag, '录音取消/超时 → WaitingForUser');
    _updateState(
      _state.copyWith(
        phase: const WaitingForUser(WaitingReason.recordingFailed),
      ),
    );
  }

  /// 释放资源
  void dispose() {
    _waitAfterCurrentPrompt = false;
    _countdown.cancel();
    _playbackService.dispose();
    _sentences = [];
  }

  // ========== 内部方法 ==========

  void _updateState(RepeatFlowState newState) {
    _state = newState;
    onStateChanged(newState);
  }

  /// 播放当前句子
  Future<void> _playCurrentSentence() async {
    final sentence = currentSentence;
    if (sentence == null) return;

    if (sentence.duration <= Duration.zero) {
      unawaited(_advanceToNextRepeatOrSentence());
      return;
    }

    await _config.onBeforeSentenceStart?.call(_state.sentenceIndex);

    _updateState(_state.copyWith(phase: const PlayingPrompt()));
    final token = _state.flowToken;
    AppLogger.log(
      logTag,
      'play-start: token=$token sentence=${sentence.index} '
      'range=${sentence.startTime.inMilliseconds}-'
      '${sentence.endTime.inMilliseconds}ms',
    );

    AppLogger.log(
      logTag,
      '播放句子 ${_state.sentenceIndex + 1}/${_state.totalSentences} '
      '第 ${_state.repeatIndex + 1}/${_state.totalRepeats} 遍',
    );

    final result = await callbacks.playSentence(sentence, token);

    AppLogger.log(
      logTag,
      'play-return: token=$token sentence=${sentence.index} '
      'phase=${_state.phase.runtimeType} result=$result',
    );

    if (result != SentencePlaybackResult.completed) {
      AppLogger.log(logTag, '播放未完成，跳过录音: result=$result token=$token');
      // 若不是用户操作已经切换了 phase，留在当前句等待重试，不能卡在播放态。
      if (token == _state.flowToken && _state.phase is PlayingPrompt) {
        _updateState(
          _state.copyWith(
            phase: const WaitingForUser(WaitingReason.recordingFailed),
          ),
        );
      }
      return;
    }
    _onPromptFinished(token);
  }

  /// 原句播放完成
  void _onPromptFinished(int token) {
    if (token != _state.flowToken) return;
    if (_state.phase is! PlayingPrompt) return;

    AppLogger.log(logTag, '原句播放完成');
    final sentence = currentSentence!;
    _config.onSentencePlayed?.call(sentence);

    if (_waitAfterCurrentPrompt) {
      _waitAfterCurrentPrompt = false;
      _updateState(
        _state.copyWith(
          repeatIndex: 0,
          totalRepeats: _config.getRepeatCount(sentence),
          intervalDuration: _config.getIntervalDuration(sentence),
          recordingPath: null,
          recordingScore: null,
          isReviewPlaybackActive: false,
          phase: const WaitingForUser(WaitingReason.userInteraction),
        ),
      );
      return;
    }

    if (_config.isManualMode()) {
      _updateState(
        _state.copyWith(
          phase: const WaitingForUser(WaitingReason.userInteraction),
        ),
      );
      return;
    }

    _startRecording();
  }

  /// 启动录音
  void _startRecording() {
    final sentence = currentSentence;
    if (sentence == null) return;

    final promptId =
        '${_config.promptIdPrefix}:${_config.audioItemId}:${sentence.index}';
    _updateState(_state.copyWith(phase: Recording(promptId: promptId)));
    AppLogger.log(
      logTag,
      'record-start: token=${_state.flowToken} sentence=${sentence.index} '
      'promptId=$promptId',
    );

    final computed =
        sentence.duration * kRecordingDurationMultiplier +
        kRecordingTimeoutBase;
    final maxDuration = computed < kRecordingMinTimeout
        ? kRecordingMinTimeout
        : computed;

    callbacks.setMaxRecordingDuration(maxDuration);

    AppLogger.log(logTag, '开始录音: $promptId');
    callbacks.startRecording(
      promptId: promptId,
      referenceText: sentence.text,
      maxDuration: maxDuration,
      referenceDuration: sentence.duration,
    );
  }

  /// 录音回放完成
  void _onReviewPlaybackFinished() {
    if (!_state.isReviewPlaybackActive) return;
    AppLogger.log(logTag, '回放结束 → WaitingForUser');
    _updateState(
      _state.copyWith(
        phase: const WaitingForUser(WaitingReason.userInteraction),
        isReviewPlaybackActive: false,
      ),
    );
  }

  /// 启动遍间倒计时
  Future<void> _startInterval({required bool resetFull}) async {
    final total = _state.intervalDuration;
    // 非重置时从 countdown controller 读取实际剩余时间
    final remaining = resetFull || !_countdown.isActive
        ? total
        : _countdown.remaining;

    _updateState(
      _state.copyWith(
        phase: WaitingInterval(remaining: remaining, total: total),
      ),
    );

    if (_config.isManualMode()) return;

    final token = _state.flowToken;
    await _countdown.start(remaining);

    if (token == _state.flowToken && _state.phase is WaitingInterval) {
      _onIntervalFinished();
    }
  }

  void _onIntervalFinished() {
    if (_state.phase is! WaitingInterval) return;
    unawaited(_advanceToNextRepeatOrSentence());
  }

  /// 推进到下一遍或下一句
  Future<void> _advanceToNextRepeatOrSentence() async {
    if (_state.isLastRepeat) {
      if (_state.isLastSentence) {
        AppLogger.log(logTag, '全部完成');
        _updateState(_state.copyWith(phase: const SessionCompleted()));
      } else {
        AppLogger.log(logTag, '当前句完成 → 下一句');
        await _jumpToSentence(_state.sentenceIndex + 1);
      }
    } else {
      final nextRepeat = _state.repeatIndex + 1;
      final flowToken = _state.flowToken + 1;
      _state = _state.copyWith(flowToken: flowToken);
      AppLogger.log(logTag, '下一遍: ${nextRepeat + 1}/${_state.totalRepeats}');
      await callbacks.clearRecording();
      if (flowToken != _state.flowToken || _state.phase is! WaitingInterval) {
        return;
      }
      _updateState(
        _state.copyWith(
          repeatIndex: nextRepeat,
          recordingPath: null,
          recordingScore: null,
          isReviewPlaybackActive: false,
          flowToken: flowToken,
        ),
      );
      await _playCurrentSentence();
    }
  }

  /// 跳转到指定句子
  Future<void> _jumpToSentence(int index) async {
    _waitAfterCurrentPrompt = false;
    _userTookOverCurrentSentence = false;
    _atomicReset();
    final flowToken = _state.flowToken;
    await callbacks.clearRecording();
    if (flowToken != _state.flowToken) return;

    final sentence = _sentences[index];
    _updateState(
      _state.copyWith(
        phase: const Idle(),
        sentenceIndex: index,
        repeatIndex: 0,
        totalRepeats: _config.getRepeatCount(sentence),
        intervalDuration: _config.getIntervalDuration(sentence),
        recordingPath: null,
        recordingScore: null,
        isReviewPlaybackActive: false,
        flowToken: flowToken,
      ),
    );

    await _playCurrentSentence();
  }

  void _atomicReset() {
    _stopActiveResources();
    _waitAfterCurrentPrompt = false;
    _state = _state.copyWith(
      flowToken: _state.flowToken + 1,
      isReviewPlaybackActive: false,
    );
  }

  void _stopActiveResources() {
    callbacks.pauseAudio();
    _countdown.cancel();
    callbacks.cancelRecording();
    _playbackService.stop();
  }
}
