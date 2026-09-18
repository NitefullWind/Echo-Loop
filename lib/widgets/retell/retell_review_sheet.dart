/// 流式展示复述 AI 评估结果的下部弹窗。
///
/// 只负责状态分发：头部（标题 + 流式进度条 + 关闭）固定，正文按 phase 切换
/// 骨架 / 报告 / 失败三态。报告正文见 [RetellReviewReport]。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../screens/external_ai_settings_screen.dart';
import '../../screens/external_speech_settings_screen.dart';
import '../../features/subscription/models/premium_feature.dart';
import '../../features/subscription/models/ai_quota_rejection.dart';
import '../../features/subscription/utils/ai_quota_copy.dart';
import '../../models/retell_review_evaluation.dart';
import '../../providers/retell_review_evaluation_provider.dart';
import '../../services/audio_preview_controller.dart';
import '../../theme/app_theme.dart';
import 'retell_review_rating_style.dart';
import 'retell_review_report.dart';

/// 把 controller 的 `errorCode` 映射成用户可见文案。
///
/// 弹窗内失败态和页面级 SnackBar 共用，保证同一失败说的是同一句话。
String retellReviewErrorMessage(
  AppLocalizations l10n,
  String? errorCode, {
  AiQuotaRejectionReason quotaReason = AiQuotaRejectionReason.exhausted,
}) => switch (errorCode) {
  'speech_not_configured' => '请先配置外部语音服务。 Configure external speech settings.',
  'text_not_configured' => '请先配置外部文本 AI。 Configure external AI settings.',
  'audio_preparation_failed' => l10n.retellAiReviewAudioPreparationError,
  'audio_too_large' => l10n.retellAiReviewAudioTooLarge,
  'auth_required' => l10n.retellAiReviewSignInRequiredTitle,
  'quota_exceeded' => aiQuotaTitleFor(
    l10n,
    PremiumFeature.aiRetellReview,
    quotaReason,
  ),
  _ => l10n.retellAiReviewError,
};

/// 打开并持续订阅当前录音 attempt 的流式评估结果。
Future<void> showRetellReviewSheet(
  BuildContext context, {
  required String recordingPath,
  required AudioPreviewController preview,
  required Future<void> Function() onBeforePlayback,
  required Future<void> Function() onRetry,
  required Future<void> Function() onUpgrade,
  required Future<void> Function() onSignIn,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (_) => _RetellReviewSheet(
    recordingPath: recordingPath,
    preview: preview,
    onBeforePlayback: onBeforePlayback,
    onRetry: onRetry,
    onUpgrade: onUpgrade,
    onSignIn: onSignIn,
  ),
);

class _RetellReviewSheet extends ConsumerWidget {
  final String recordingPath;
  final AudioPreviewController preview;
  final Future<void> Function() onBeforePlayback;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUpgrade;
  final Future<void> Function() onSignIn;

  const _RetellReviewSheet({
    required this.recordingPath,
    required this.preview,
    required this.onBeforePlayback,
    required this.onRetry,
    required this.onUpgrade,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(retellReviewEvaluationProvider);
    final evaluation = state.evaluation;
    final isPending =
        state.phase == RetellReviewEvaluationPhase.loading ||
        state.phase == RetellReviewEvaluationPhase.streaming;
    return SafeArea(
      top: false,
      child: SizedBox(
        key: const ValueKey('retell-review-sheet'),
        height: MediaQuery.sizeOf(context).height * .80,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.m,
            AppSpacing.xs,
            AppSpacing.m,
            AppSpacing.m,
          ),
          child: Column(
            children: [
              const _DragHandle(),
              const SizedBox(height: AppSpacing.xs),
              _SheetHeader(title: l10n.retellAiReviewTitle),
              const SizedBox(height: AppSpacing.xs),
              _StreamProgressBar(isActive: isPending),
              const SizedBox(height: AppSpacing.s),
              Expanded(child: _buildBody(l10n, state, evaluation)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    AppLocalizations l10n,
    RetellReviewEvaluationState state,
    RetellReviewEvaluation? evaluation,
  ) {
    if (state.phase == RetellReviewEvaluationPhase.failed) {
      return _ReviewFailure(
        errorCode: state.errorCode,
        message:
            state.errorMessage ??
            retellReviewErrorMessage(
              l10n,
              state.errorCode,
              quotaReason: state.quotaReason,
            ),
        onRetry: onRetry,
        onUpgrade: onUpgrade,
        onSignIn: onSignIn,
      );
    }
    if (evaluation == null) return const _ReviewSkeleton();
    return RetellReviewReport(
      evaluation: evaluation,
      isStreaming: state.phase == RetellReviewEvaluationPhase.streaming,
      recordingPath: recordingPath,
      preview: preview,
      onBeforePlayback: onBeforePlayback,
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 4,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.outlineVariant,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

/// 弹窗标题行。
///
/// 整行高度钉在 [_headerRowHeight]：报告本身信息密度高，头部只做身份标识，
/// 不值得占掉一屏的十分之一。关闭按钮必须显式收掉 [IconButton] 默认的 48×48
/// 点击区，否则它会独自把标题行撑到 48。
class _SheetHeader extends StatelessWidget {
  static const _headerRowHeight = 32.0;

  final String title;

  const _SheetHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _headerRowHeight,
      child: Row(
        children: [
          // 裸图标而非色块容器：与入口胶囊、其他 sheet 标题保持同一克制风格
          Icon(
            Icons.auto_awesome_rounded,
            size: 18,
            color: theme.colorScheme.primary.withValues(alpha: .8),
          ),
          const SizedBox(width: AppSpacing.xs + 2),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox.square(
            dimension: _headerRowHeight,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              padding: EdgeInsets.zero,
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded),
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式进行中的细进度条；非流式阶段保留同高度占位，避免正文上下跳动。
class _StreamProgressBar extends StatelessWidget {
  final bool isActive;

  const _StreamProgressBar({required this.isActive});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 3,
    child: isActive
        ? ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.outlineVariant.withValues(alpha: .4),
            ),
          )
        : null,
  );
}

/// 首帧到达前的骨架：保留报告的版式骨骼，比裸转圈更能预告内容结构。
class _ReviewSkeleton extends StatelessWidget {
  const _ReviewSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    children: const [
      _SkeletonBlock(height: 112, radius: 20),
      SizedBox(height: AppSpacing.l),
      _SkeletonBlock(height: 14, radius: 7, width: 96),
      SizedBox(height: AppSpacing.s),
      _SkeletonBlock(height: 148, radius: 16),
    ],
  );
}

class _SkeletonBlock extends StatelessWidget {
  final double height;
  final double radius;
  final double? width;

  const _SkeletonBlock({
    required this.height,
    required this.radius,
    this.width,
  });

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        // 与正式卡片同底色：否则加载态是深灰块，首帧到达时整屏「刷」地变白。
        color: retellCardFill(context),
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
  );
}

/// 失败态：按 errorCode 说清原因，并给出对应的唯一出路。
///
/// 未登录与额度用尽不能给「重试」——重试必然再撞同一堵墙，还白跑一次本地转码
/// 与 2MB 上传。这两种码分别换成登录与升级入口。
class _ReviewFailure extends StatelessWidget {
  final String? errorCode;
  final String message;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUpgrade;
  final Future<void> Function() onSignIn;

  const _ReviewFailure({
    required this.errorCode,
    required this.message,
    required this.onRetry,
    required this.onUpgrade,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final (actionLabel, actionIcon, onAction) = switch (errorCode) {
      'speech_not_configured' || 'text_not_configured' => (
        '设置 / Settings',
        Icons.settings_rounded,
        () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => errorCode == 'speech_not_configured'
                  ? const ExternalSpeechSettingsScreen()
                  : const ExternalAiSettingsScreen(),
            ),
          );
        },
      ),
      'quota_exceeded' => (
        l10n.aiQuotaExceededSubscribe,
        Icons.workspace_premium_rounded,
        onUpgrade,
      ),
      'auth_required' => (l10n.authSignInButton, Icons.login_rounded, onSignIn),
      _ => (l10n.retellAiReviewRetry, Icons.refresh_rounded, onRetry),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.cloud_off_rounded,
                size: 26,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: AppSpacing.m),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.l),
            FilledButton.tonalIcon(
              onPressed: onAction,
              icon: Icon(actionIcon, size: 18),
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
