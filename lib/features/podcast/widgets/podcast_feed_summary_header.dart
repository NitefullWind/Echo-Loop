/// Podcast feed 摘要头部。
///
/// 搜索预览页和已订阅 Podcast 合集详情页共用同一套紧凑展示：左侧封面，
/// 右侧最多 4 行简介，并把「更多」内联放在最后一行末尾。
library;

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import 'podcast_subscribe_tile.dart';

class PodcastFeedSummaryHeader extends StatelessWidget {
  final String? imageUrl;
  final String? description;
  final String moreLabel;
  final VoidCallback onTap;
  final EdgeInsetsGeometry padding;
  final double coverSize;

  const PodcastFeedSummaryHeader({
    super.key,
    required this.imageUrl,
    required this.description,
    required this.moreLabel,
    required this.onTap,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.m,
      AppSpacing.m,
      AppSpacing.m,
      AppSpacing.s,
    ),
    this.coverSize = 72,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PodcastCover(imageUrl: imageUrl, size: coverSize),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: _InlineMoreDescription(
                  description: description,
                  moreLabel: moreLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 简介文本：按可用宽度截断，并保留「更多」可见。
class _InlineMoreDescription extends StatelessWidget {
  final String? description;
  final String moreLabel;

  const _InlineMoreDescription({
    required this.description,
    required this.moreLabel,
  });

  static const int _maxLines = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 摘要是辅助信息，使用正文级字号，避免在窄屏时压过播客标题层级。
    final descriptionStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.3,
    );
    final moreStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.primary,
      height: 1.25,
    );
    final text = _compact(description);

    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = constraints.maxWidth.isFinite
            ? _fitDescription(
                context: context,
                text: text,
                moreLabel: moreLabel,
                width: constraints.maxWidth,
                descriptionStyle: descriptionStyle,
                moreStyle: moreStyle,
              )
            : text;
        return Text.rich(
          TextSpan(
            children: [
              if (fitted.isNotEmpty) TextSpan(text: fitted),
              if (fitted.isNotEmpty) const TextSpan(text: ' '),
              TextSpan(text: moreLabel, style: moreStyle),
            ],
          ),
          key: const ValueKey('podcast-feed-summary-inline-more'),
          style: descriptionStyle,
          maxLines: _maxLines,
          overflow: TextOverflow.clip,
        );
      },
    );
  }

  String _fitDescription({
    required BuildContext context,
    required String text,
    required String moreLabel,
    required double width,
    required TextStyle? descriptionStyle,
    required TextStyle? moreStyle,
  }) {
    if (text.isEmpty) return '';
    if (_fits(
      context: context,
      width: width,
      descriptionStyle: descriptionStyle,
      moreStyle: moreStyle,
      descriptionText: text,
      moreLabel: moreLabel,
    )) {
      return text;
    }

    var low = 0;
    var high = text.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      final candidate = '${text.substring(0, mid).trimRight()}...';
      if (_fits(
        context: context,
        width: width,
        descriptionStyle: descriptionStyle,
        moreStyle: moreStyle,
        descriptionText: candidate,
        moreLabel: moreLabel,
      )) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    if (low == 0) return '...';
    return '${text.substring(0, low).trimRight()}...';
  }

  bool _fits({
    required BuildContext context,
    required double width,
    required TextStyle? descriptionStyle,
    required TextStyle? moreStyle,
    required String descriptionText,
    required String moreLabel,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        style: descriptionStyle,
        children: [
          if (descriptionText.isNotEmpty) TextSpan(text: descriptionText),
          if (descriptionText.isNotEmpty) const TextSpan(text: ' '),
          TextSpan(text: moreLabel, style: moreStyle),
        ],
      ),
      maxLines: _maxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    return !painter.didExceedMaxLines;
  }

  String _compact(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return '';
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }
}
