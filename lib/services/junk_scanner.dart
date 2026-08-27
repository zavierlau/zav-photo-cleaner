import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/junk_file.dart';

/// 掃描手機常見垃圾／快取位置。
///
/// - App 自家快取目錄（getTemporaryDirectory / getCacheDirectory）。
/// - Android Download 資料夾入面嘅安裝包／暫存／日誌檔（.apk/.tmp/.log 等）。
///
/// 注意：Web 平台唔支援檔案系統，會直接傳返空列表。
class JunkScanner {
  JunkScanner._();

  /// 會當做「下載垃圾」處理嘅副檔名（Download 資料夾內）。
  static const Set<String> junkExtensions = {
    '.apk', '.tmp', '.log', '.zip', '.rar', '.7z', '.bak', '.cache', '.crdownload',
  };

  /// 掃描並傳返全部搵到嘅垃圾檔案。
  static Future<List<JunkFile>> scanJunk() async {
    if (kIsWeb) return <JunkFile>[];
    final Map<String, JunkFile> found = <String, JunkFile>{};

    // 1) App 自家快取（getTemporaryDirectory == Android cache dir）。
    try {
      final Directory temp = await getTemporaryDirectory();
      await _collectDirectory(temp.path, found, scanAll: true, category: '快取');
    } catch (_) {}

    // 2) Android 另一個快取目錄（若同上面重複，`found` map 會自動去重）。
    try {
      final Directory cache = await getApplicationCacheDirectory();
      await _collectDirectory(cache.path, found, scanAll: true, category: '快取');
    } catch (_) {}

    // 3) App 外部快取（/storage/emulated/0/Android/data/<pkg>/cache）。
    try {
      final List<Directory>? extCache = await getExternalCacheDirectories();
      if (extCache != null) {
        for (final Directory d in extCache) {
          await _collectDirectory(d.path, found, scanAll: true, category: '快取');
        }
      }
    } catch (_) {}

    // 4) Android Download 資料夾入面嘅安裝包／暫存／日誌。
    try {
      final Directory download = Directory('/storage/emulated/0/Download');
      if (await download.exists()) {
        await _collectDirectory(
          download.path,
          found,
          extensions: junkExtensions,
          category: '下載垃圾',
        );
      }
    } catch (_) {}

    final List<JunkFile> list = found.values.toList()
      ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return list;
  }

  /// 遞歸掃描一個目錄。
  ///
  /// - [scanAll]：已經掃全部檔案（快取類）。
  /// - [extensions]：只掃副檔名喺指定集合內（Download 垃圾類）。
  static Future<void> _collectDirectory(
    String dirPath,
    Map<String, JunkFile> found, {
    bool scanAll = false,
    Set<String>? extensions,
    required String category,
    int depth = 0,
  }) async {
    if (depth > 6) return; // 避免行得太深
    final Directory dir = Directory(dirPath);
    try {
      if (!await dir.exists()) return;
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        try {
          if (entity is File) {
            final String path = entity.path;
            final String name = entity.uri.pathSegments.isNotEmpty
                ? entity.uri.pathSegments.last
                : path;
            final int dot = name.lastIndexOf('.');
            final String ext =
                dot > 0 ? name.substring(dot).toLowerCase() : '';
            final bool match = scanAll || (extensions?.contains(ext) ?? false);
            if (!match) continue;
            if (found.containsKey(path)) continue;
            final int size = await _safeSize(entity);
            if (size <= 0) continue;
            found[path] = JunkFile(
              path: path,
              name: name,
              sizeBytes: size,
              category: category,
              ext: ext,
            );
          } else if (entity is Directory && depth < 6) {
            await _collectDirectory(
              entity.path,
              found,
              scanAll: scanAll,
              extensions: extensions,
              category: category,
              depth: depth + 1,
            );
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<int> _safeSize(File f) async {
    try {
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// 刪除一批垃圾檔案，傳返成功刪除嘅數量。
  static Future<int> deleteJunkFiles(List<JunkFile> files) async {
    if (kIsWeb) return 0;
    int ok = 0;
    for (final JunkFile j in files) {
      try {
        final File f = File(j.path);
        if (await f.exists()) {
          await f.delete();
          ok++;
        }
      } catch (e) {
        debugPrint('JunkScanner.delete error: $e');
      }
    }
    return ok;
  }
}
