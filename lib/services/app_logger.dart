/// 应用内日志服务。
///
/// 内存环形缓冲区用于实时展示；持久化由 `logger` 的
/// [AdvancedFileOutput] 负责大小轮转。日志页面按需读取文件，启动阶段不会读取
/// 或截断历史日志。
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logger/logger.dart';

/// 单条日志。
class LogEntry {
  final DateTime time;
  final String tag;
  final String message;

  const LogEntry({
    required this.time,
    required this.tag,
    required this.message,
  });

  @override
  String toString() => AppLogger.formatLine(time, tag, message);
}

/// 应用内日志服务（内存最多保留 500 条）。
class AppLogger {
  AppLogger._();
  static final instance = AppLogger._();

  /// 日志页和内存环形缓冲区统一保留的最近日志条数。
  static const maxRetainedEntries = 500;
  static const _defaultMaxFileSizeKB = 5 * 1024;
  static const _latestFileName = 'app.log';

  final _entries = Queue<LogEntry>();
  final _listeners = <void Function()>[];

  static AdvancedFileOutput? _fileOutput;
  static String? _logDirectory;

  /// 所有内存日志（只读，仅当前进程）。
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 统一的单行日志格式：`HH:MM:SS.mmm [tag] message`。
  static String formatLine(DateTime time, String tag, String message) {
    final t =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
    return '$t [$tag] $message';
  }

  /// 配置持久化日志输出。
  ///
  /// 当前文件固定为 `app.log`，单个文件最大 5 MB，并最多保留一个历史轮转文件。
  /// 已在内存中的启动日志会在输出可用后写入；此方法不读取历史日志。
  static Future<void> configurePersistentOutput(String logDirectory) {
    return _configureOutput(logDirectory);
  }

  /// 仅供测试释放第三方输出的轮转计时器，避免测试进程残留异步句柄。
  @visibleForTesting
  static Future<void> resetPersistentOutputForTesting() async {
    final output = _fileOutput;
    _fileOutput = null;
    _logDirectory = null;
    await output?.destroy();
  }

  static Future<void> _configureOutput(String logDirectory) async {
    final previous = _fileOutput;
    _fileOutput = null;
    await previous?.destroy();

    final output = AdvancedFileOutput(
      path: logDirectory,
      latestFileName: _latestFileName,
      maxFileSizeKB: _defaultMaxFileSizeKB,
      maxRotatedFilesCount: 1,
      // 现有 AppLogger 没有等级区分；全部尽快交给文件输出写入。
      writeImmediately: const [Level.info],
      fileUpdateDuration: const Duration(seconds: 1),
      fileNameFormatter: _rotatedFileName,
    );
    await output.init();
    _logDirectory = logDirectory;
    _fileOutput = output;

    for (final entry in instance._entries) {
      _writeToPersistentOutput(entry);
    }
  }

  /// 流式读取持久化日志的尾部，供日志页面恢复最近记录。
  ///
  /// 文件按时间从旧到新逐行读取，内存中始终只保留最后 [limit] 条，避免把
  /// 多个轮转文件拼接成一个大字符串。完整日志分享由日志页面直接打包原文件，
  /// 不经过此接口。
  static Future<List<LogEntry>> readRecentPersistedEntries({
    int limit = maxRetainedEntries,
  }) async {
    if (limit <= 0) return const <LogEntry>[];
    final directory = _logDirectory;
    if (directory == null) return const <LogEntry>[];

    final recentEntries = Queue<LogEntry>();
    try {
      final files = await _logFilesOldestFirst(directory);
      for (final file in files) {
        final lines = file
            .openRead()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter());
        await for (final line in lines) {
          final entry = _parsePersistedLine(line);
          if (entry == null) continue;
          if (recentEntries.length >= limit) recentEntries.removeFirst();
          recentEntries.addLast(entry);
        }
      }
      return List<LogEntry>.unmodifiable(recentEntries);
    } catch (error) {
      // 日志读取失败不可影响主流程，但控制台保留诊断信息。
      print('读取最近持久化日志失败: $error');
      return List<LogEntry>.unmodifiable(recentEntries);
    }
  }

  /// 清空内存日志。持久化日志由 [clearPersistedLogs] 显式清理，避免测试和普通
  /// 内存重置意外触碰磁盘。
  void clear() {
    _entries.clear();
    _notifyListeners();
  }

  /// 清空活动和历史日志，然后恢复同一份大小轮转配置。
  static Future<void> clearPersistedLogs() async {
    final directory = _logDirectory;
    instance.clear();
    if (directory == null) return;

    final output = _fileOutput;
    _fileOutput = null;
    await output?.destroy();
    try {
      final logDirectory = Directory(directory);
      if (await logDirectory.exists()) {
        await for (final entity in logDirectory.list()) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (error) {
      print('清空持久化日志失败: $error');
    }
    await configurePersistentOutput(directory);
  }

  /// 记录日志：输出控制台、内存缓冲和已配置的持久化文件。
  static void log(String tag, String message) {
    final entry = LogEntry(time: DateTime.now(), tag: tag, message: message);
    // ignore: avoid_print
    print(entry);
    _writeToPersistentOutput(entry);

    final logger = instance;
    logger._entries.addLast(entry);
    if (logger._entries.length > maxRetainedEntries) {
      logger._entries.removeFirst();
    }
    logger._notifyListeners();
  }

  static void _writeToPersistentOutput(LogEntry entry) {
    try {
      _fileOutput?.output(
        OutputEvent(LogEvent(Level.info, entry.message, time: entry.time), [
          entry.toString(),
        ]),
      );
    } catch (error) {
      // 输出失败不能递归写 AppLogger；控制台保留失败原因。
      print('写入持久化日志失败: $error');
    }
  }

  static Future<List<File>> _logFilesOldestFirst(String logDirectory) async {
    final directory = Directory(logDirectory);
    if (!await directory.exists()) return const [];
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) {
      final aIsLatest = a.path == '${directory.path}/$_latestFileName';
      final bIsLatest = b.path == '${directory.path}/$_latestFileName';
      if (aIsLatest) return 1;
      if (bIsLatest) return -1;
      return a.lastModifiedSync().compareTo(b.lastModifiedSync());
    });
    return files;
  }

  static String _rotatedFileName(DateTime time) {
    final timestamp = time.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    return 'app-$timestamp.log';
  }

  static LogEntry? _parsePersistedLine(String line) {
    final match = RegExp(
      r'^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[([^\]]+)\] (.*)$',
    ).firstMatch(line);
    if (match == null) return null;
    final hour = match.group(1);
    final minute = match.group(2);
    final second = match.group(3);
    final millisecond = match.group(4);
    final tag = match.group(5);
    final message = match.group(6);
    if (hour == null ||
        minute == null ||
        second == null ||
        millisecond == null ||
        tag == null ||
        message == null) {
      return null;
    }
    final now = DateTime.now();
    return LogEntry(
      time: DateTime(
        now.year,
        now.month,
        now.day,
        int.parse(hour),
        int.parse(minute),
        int.parse(second),
        int.parse(millisecond),
      ),
      tag: tag,
      message: message,
    );
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// 添加监听器（日志页面用于刷新 UI）。
  void addListener(void Function() listener) => _listeners.add(listener);

  /// 移除监听器。
  void removeListener(void Function() listener) => _listeners.remove(listener);
}
