/// 学习阶段枚举（用于按阶段统计每日听说时长）
///
/// 每个值对应一种学习活动。Drift 使用 `intEnum` 按 [index] 存储，
/// 发布后枚举顺序不可改动，新增值只能追加到末尾。
enum StudyStage {
  /// 全文盲听
  blindListen(0),

  /// 逐句精听
  intensiveListen(1),

  /// 跟读
  listenAndRepeat(2),

  /// 段落复述
  retell(3),

  /// 难句补练
  reviewDifficultPractice(4),

  /// 收藏句复习
  savedSentencesReview(5),

  /// 收藏词汇复习
  savedVocabularyReview(6),

  /// 随心听
  freePlayer(7);

  const StudyStage(this.value);

  /// 数据库存储值（= index，显式声明防止误改顺序）
  final int value;

  /// 从数据库整数值还原枚举
  static StudyStage? fromValue(int value) {
    if (value < 0 || value >= StudyStage.values.length) return null;
    return StudyStage.values[value];
  }
}
