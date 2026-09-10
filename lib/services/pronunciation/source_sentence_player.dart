import '../../database/daos/audio_item_dao.dart';
import '../../models/sentence.dart';
import '../app_logger.dart';
import '../subtitle_parser.dart';
import 'local_audio_clip_player.dart';
import 'local_audio_range_player.dart';

/// 收藏词汇与意群共用的来源句播放编排。
///
/// 只负责一次性来源句试听：原音区间成功时不触发 TTS，原音不可用时
/// 才通过注入的回调朗读文本。播放器本身由调用方注入，保持生命周期归属。
class SourceSentencePlayer {
  SourceSentencePlayer({
    required AudioItemDao audioItemDao,
    required LocalAudioClipPlayer audioClipPlayer,
    required Future<AudioPlaybackResult> Function(
      String text,
      String playbackKey,
    )
    speak,
    bool Function()? isPlaybackCurrent,
  }) : _audioItemDao = audioItemDao,
       _audioClipPlayer = audioClipPlayer,
       _speak = speak,
       _isPlaybackCurrent = isPlaybackCurrent ?? _alwaysCurrent;

  final AudioItemDao _audioItemDao;
  final LocalAudioClipPlayer _audioClipPlayer;
  final Future<AudioPlaybackResult> Function(String text, String playbackKey)
  _speak;
  final bool Function() _isPlaybackCurrent;

  static bool _alwaysCurrent() => true;

  /// 播放来源句并返回整个播放链路的真实终态。
  ///
  /// 本地原音失败时才允许继续尝试其他本地来源或 TTS；明确取消时必须停止
  /// 回退，避免用户停止原音后又被 TTS 重新播放。
  Future<AudioPlaybackResult> play({
    required String? audioItemId,
    required int? sentenceIndex,
    required String? sentenceText,
    required int? sentenceStartMs,
    required int? sentenceEndMs,
    required String playbackKey,
  }) async {
    final text = sentenceText?.trim();
    if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
    try {
      final row = audioItemId == null
          ? null
          : await _audioItemDao.getById(audioItemId);
      if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
      if (row != null) {
        final filePath = await audioItemFromDatabaseRow(row).getFullAudioPath();
        if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
        final range = _resolveStoredRange(sentenceStartMs, sentenceEndMs);
        if (filePath != null && range != null) {
          final result = await _audioClipPlayer.playRangeFile(
            filePath,
            start: range.$1,
            end: range.$2,
            playbackKey: playbackKey,
          );
          if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
          switch (result) {
            case AudioPlaybackResult.completed:
              return AudioPlaybackResult.completed;
            case AudioPlaybackResult.cancelled:
              return AudioPlaybackResult.cancelled;
            case AudioPlaybackResult.failed:
              break;
          }
        }

        final srt = await _audioItemDao.getTranscriptSrt(row.id);
        if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
        if (srt != null && srt.isNotEmpty && text != null) {
          final sentences = await SubtitleParser.parseSubtitleString(srt);
          if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
          Sentence? sentence =
              sentenceIndex != null &&
                  sentenceIndex >= 0 &&
                  sentenceIndex < sentences.length
              ? sentences[sentenceIndex]
              : null;
          if (sentence == null || sentence.text.trim() != text) {
            sentence = sentences.cast<Sentence?>().firstWhere(
              (candidate) => candidate!.text.trim() == text,
              orElse: () => null,
            );
          }
          if (filePath != null && sentence != null) {
            final result = await _audioClipPlayer.playRangeFile(
              filePath,
              start: sentence.startTime,
              end: sentence.endTime,
              playbackKey: playbackKey,
            );
            if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
            switch (result) {
              case AudioPlaybackResult.completed:
                return AudioPlaybackResult.completed;
              case AudioPlaybackResult.cancelled:
                return AudioPlaybackResult.cancelled;
              case AudioPlaybackResult.failed:
                break;
            }
          }
        }
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'SourceSentencePlayer',
        'local source playback failed error=$error\n$stackTrace',
      );
    }
    if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
    if (text != null && text.isNotEmpty) {
      try {
        if (!_isPlaybackCurrent()) return AudioPlaybackResult.cancelled;
        return await _speak(text, playbackKey);
      } catch (error, stackTrace) {
        AppLogger.log(
          'SourceSentencePlayer',
          'TTS fallback failed error=$error\n$stackTrace',
        );
      }
    }
    return AudioPlaybackResult.failed;
  }

  (Duration, Duration)? _resolveStoredRange(int? startMs, int? endMs) {
    if (startMs == null || endMs == null || endMs - startMs < 200) {
      return null;
    }
    return (Duration(milliseconds: startMs), Duration(milliseconds: endMs));
  }
}
