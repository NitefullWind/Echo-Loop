import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/study_stage.dart';

/// 学习阶段在任务卡片和统计明细中的共用展示定义。
///
/// 名称、图标和颜色必须从同一处读取，避免学习计划与学习统计出现不同
/// 的任务语义或视觉标识。
class StudyStageVisual {
  /// 阶段图标。
  final IconData icon;

  /// 阶段图标颜色；未指定时由调用方提供中性色。
  final Color? iconColor;

  /// 阶段名称。
  final String name;

  const StudyStageVisual({
    required this.icon,
    required this.name,
    this.iconColor,
  });
}

/// 返回学习阶段的统一名称、图标和颜色。
StudyStageVisual studyStageVisual(StudyStage stage, AppLocalizations l10n) =>
    switch (stage) {
      StudyStage.blindListen => StudyStageVisual(
        icon: Icons.headphones,
        iconColor: Colors.blue,
        name: l10n.stepBlindListening,
      ),
      StudyStage.intensiveListen => StudyStageVisual(
        icon: Icons.hearing,
        iconColor: Colors.indigo,
        name: l10n.stepIntensiveListening,
      ),
      StudyStage.listenAndRepeat => StudyStageVisual(
        icon: Icons.record_voice_over,
        iconColor: Colors.orange,
        name: l10n.stepShadowing,
      ),
      StudyStage.retell => StudyStageVisual(
        icon: Icons.chat,
        iconColor: Colors.teal,
        name: l10n.stepRetelling,
      ),
      StudyStage.reviewDifficultPractice => StudyStageVisual(
        icon: Icons.fitness_center,
        iconColor: Colors.orange,
        name: l10n.reviewDifficultPracticeTitle,
      ),
      StudyStage.savedSentencesReview => StudyStageVisual(
        icon: Icons.subject,
        name: l10n.stageBookmarkReview,
      ),
      StudyStage.savedVocabularyReview => StudyStageVisual(
        icon: Icons.menu_book_outlined,
        name: l10n.stageFlashcard,
      ),
      StudyStage.freePlayer => StudyStageVisual(
        icon: Icons.headphones_outlined,
        name: l10n.freePlay,
      ),
    };
