/// 跟读流程状态（不可变数据类）
///
/// 由 [RepeatFlowEngine] 管理，通过 [onStateChanged] 通知外部。
/// 各页面的 Controller/Provider 可包装此状态或直接暴露给 UI。
library;

import 'repeat_flow_phase.dart';

/// 跟读流程的长期控制模式。
///
/// 用户打断自动流程不是独立模式，而是当前句的一次性流程事件。
enum RepeatControlMode {
  /// 自动播放、录音和句间推进。
  automatic,

  /// 所有步骤由用户显式操作。
  manual,
}

/// 当前句录音评估完成后的推进策略。
///
/// 该策略只属于当前句上下文，不表示用户选择的全局控制模式。
enum RepeatPostRecordingAction {
  /// 评估成功后启动遍间倒计时。
  startInterval,

  /// 评估成功后保持等待用户操作。
  waitForUser,
}

/// 切句请求的来源，用于统一导航事务和诊断竞态。
enum RepeatNavigationSource {
  /// 点击下一句。
  nextArrow,

  /// 点击上一句。
  previousArrow,

  /// 用户滑动分页器。
  swipe,

  /// 自动倒计时完成后的推进。
  automatic,

  /// 进度条或其它显式跳转。
  explicit,
}

/// 跟读流程状态
class RepeatFlowState {
  /// 当前跟读会话标识，用于隔离迟到的异步回调。
  final int sessionId;

  /// 当前阶段
  final RepeatFlowPhase phase;

  /// 当前句子索引（0-based）
  final int sentenceIndex;

  /// 句子总数
  final int totalSentences;

  /// 当前遍次（0-based）
  final int repeatIndex;

  /// 总遍数。`0` 表示无限重复当前句。
  final int totalRepeats;

  /// 遍间倒计时总时长（配置值）
  final Duration intervalDuration;

  /// 录音文件路径
  final String? recordingPath;

  /// 录音评分
  final double? recordingScore;

  /// 录音回放是否正在播放。
  ///
  /// 与 [phase] 分离，避免 UI 把“处于回放阶段”和“正在播放回放”混为一谈。
  final bool isReviewPlaybackActive;

  /// 流程令牌（异步回调校验用）
  final int flowToken;

  /// 用户选择的长期控制模式。
  final RepeatControlMode controlMode;

  /// 当前句录音评估完成后的推进策略。
  final RepeatPostRecordingAction postRecordingAction;

  /// 是否正在执行切句事务。
  final bool isTransitioning;

  const RepeatFlowState({
    this.sessionId = 0,
    this.phase = const Idle(),
    this.sentenceIndex = 0,
    this.totalSentences = 0,
    this.repeatIndex = 0,
    this.totalRepeats = 1,
    this.intervalDuration = Duration.zero,
    this.recordingPath,
    this.recordingScore,
    this.isReviewPlaybackActive = false,
    this.flowToken = 0,
    this.controlMode = RepeatControlMode.automatic,
    this.postRecordingAction = RepeatPostRecordingAction.startInterval,
    this.isTransitioning = false,
  });

  RepeatFlowState copyWith({
    int? sessionId,
    RepeatFlowPhase? phase,
    int? sentenceIndex,
    int? totalSentences,
    int? repeatIndex,
    int? totalRepeats,
    Duration? intervalDuration,
    Object? recordingPath = _noChange,
    Object? recordingScore = _noChange,
    bool? isReviewPlaybackActive,
    int? flowToken,
    RepeatControlMode? controlMode,
    RepeatPostRecordingAction? postRecordingAction,
    bool? isTransitioning,
  }) {
    return RepeatFlowState(
      sessionId: sessionId ?? this.sessionId,
      phase: phase ?? this.phase,
      sentenceIndex: sentenceIndex ?? this.sentenceIndex,
      totalSentences: totalSentences ?? this.totalSentences,
      repeatIndex: repeatIndex ?? this.repeatIndex,
      totalRepeats: totalRepeats ?? this.totalRepeats,
      intervalDuration: intervalDuration ?? this.intervalDuration,
      recordingPath: identical(recordingPath, _noChange)
          ? this.recordingPath
          : recordingPath as String?,
      recordingScore: identical(recordingScore, _noChange)
          ? this.recordingScore
          : recordingScore as double?,
      isReviewPlaybackActive:
          isReviewPlaybackActive ?? this.isReviewPlaybackActive,
      flowToken: flowToken ?? this.flowToken,
      controlMode: controlMode ?? this.controlMode,
      postRecordingAction: postRecordingAction ?? this.postRecordingAction,
      isTransitioning: isTransitioning ?? this.isTransitioning,
    );
  }

  // ========== 便捷 getter ==========

  /// 是否为最后一句
  bool get isLastSentence => sentenceIndex >= totalSentences - 1;

  /// 是否为第一句
  bool get isFirstSentence => sentenceIndex <= 0;

  /// 是否为最后一遍
  bool get isInfiniteRepeat => totalRepeats == 0;

  bool get isLastRepeat => !isInfiniteRepeat && repeatIndex >= totalRepeats - 1;

  /// 是否在倒计时中
  bool get isCountingDown => phase is WaitingInterval;

  /// 是否在等待用户操作
  bool get isWaitingForUser => phase is WaitingForUser;

  /// 是否处于停顿状态（包含 Recording：播放已结束，等待用户操作或录音完成）
  bool get isInPause =>
      phase is WaitingInterval || phase is WaitingForUser || phase is Recording;

  /// 是否已完成
  bool get isCompleted =>
      phase is SentenceCompleted || phase is SessionCompleted;
}

const _noChange = Object();
