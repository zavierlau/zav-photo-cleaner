import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/analysis_result.dart';

/// 垃圾桶入面嘅一個條目（已由原位置 copy 去 app 私人 trash 目錄）。
class TrashEntry {
  /// 喺 trash 目錄內嘅唯一 key（檔名主體）。
  final String key;

  /// 副檔名（以 "." 開頭，或空字串）。
  final String ext;

  /// 原本路徑（刪除前記錄），可用嚟還原返原位。
  final String? originalPath;

  /// 原本檔名／標題。
  final String title;

  /// 'image' 或 'video'。
  final String type;

  final int sizeBytes;

  final DateTime date;

  /// trash 目錄絕對路徑（由 TrashManager 注入）。
  final String trashDir;

  TrashEntry({
    required this.key,
    required this.ext,
    required this.originalPath,
    required this.title,
    required this.type,
    required this.sizeBytes,
    required this.date,
    required this.trashDir,
  });

  String get filePath => '$trashDir/$key$ext';
  String get id => key;

  double get sizeMB => sizeBytes / (1024 * 1024);

  factory TrashEntry.fromJson(Map<String, dynamic> json, String trashDir) {
    return TrashEntry(
      key: json['key'] as String? ?? '',
      ext: json['ext'] as String? ?? '',
      originalPath: json['originalPath'] as String?,
      title: json['title'] as String? ?? '未命名',
      type: json['type'] as String? ?? 'image',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      date: DateTime.tryParse(json['date'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      trashDir: trashDir,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'ext': ext,
        'originalPath': originalPath,
        'title': title,
        'type': type,
        'sizeBytes': sizeBytes,
        'date': date.toIso8601String(),
      };
}

/// 垃圾桶管理器：刪除相片／影片前，先將原檔 copy 去 app 私人目錄
/// （getApplicationDocumentsDirectory()/trash/），copy 成功先刪原檔，
/// 之後可以將條目「還原」返原位或儲存。
///
/// Web 平台冇檔案系統支援，所有操作都會安全地傳返 false／空列表。
class TrashManager {
  TrashManager._();

  static Directory? _trashDir;

  static Future<Directory> trashDir() async {
    if (kIsWeb) throw UnsupportedError('Web 平台唔支援垃圾桶');
    if (_trashDir != null) return _trashDir!;
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${docs.path}${Platform.pathSeparator}trash');
    await dir.create(recursive: true);
    _trashDir = dir;
    return dir;
  }

  static File _manifestFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}manifest.json');

  static Future<List<Map<String, dynamic>>> _loadEntries() async {
    if (kIsWeb) return <Map<String, dynamic>>[];
    try {
      final Directory dir = await trashDir();
      final File f = _manifestFile(dir);
      if (await f.exists()) {
        final dynamic decoded = jsonDecode(await f.readAsString());
        final List<dynamic> list =
            (decoded is Map && decoded['entries'] is List)
                ? decoded['entries'] as List<dynamic>
                : <dynamic>[];
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      debugPrint('TrashManager load entries error: $e');
    }
    return <Map<String, dynamic>>[];
  }

  static Future<void> _saveEntries(List<Map<String, dynamic>> entries) async {
    final Directory dir = await trashDir();
    await _manifestFile(dir).writeAsString(
      jsonEncode(<String, dynamic>{'entries': entries}),
    );
  }

  /// 刪除前備份：將 [item] 原檔 copy 去 trash。傳返是否成功。
  /// 只有 copy 成功先應該繼續刪原檔。
  static Future<bool> backup(AssetItem item) async {
    if (kIsWeb) return false;
    try {
      File? src;
      try {
        src = await item.entity.originFile;
      } catch (_) {}
      src ??= await item.entity.file;
      if (src == null || !await src.exists()) return false;

      final Directory dir = await trashDir();
      final String cleanId =
          item.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
      final String key =
          '${DateTime.now().millisecondsSinceEpoch}_$cleanId';
      final String ext =
          src.path.contains('.') ? src.path.substring(src.path.lastIndexOf('.')) : '';

      final File dest = File('${dir.path}${Platform.pathSeparator}$key$ext');
      await src.copy(dest.path);

      final List<Map<String, dynamic>> entries = await _loadEntries();
      entries.add(<String, dynamic>{
        'key': key,
        'ext': ext,
        'originalPath': src.path,
        'title': (item.entity.title?.isNotEmpty ?? false)
            ? item.entity.title
            : item.id,
        'type': item.isVideo ? 'video' : 'image',
        'sizeBytes': item.sizeBytes,
        'date': DateTime.now().toIso8601String(),
      });
      await _saveEntries(entries);
      return true;
    } catch (e) {
      debugPrint('TrashManager.backup error: $e');
      return false;
    }
  }

  /// 列出垃圾桶入面全部條目（最新在前）。
  static Future<List<TrashEntry>> list() async {
    if (kIsWeb) return <TrashEntry>[];
    try {
      final Directory dir = await trashDir();
      final List<Map<String, dynamic>> entries = await _loadEntries();
      final List<TrashEntry> out = entries
          .map((e) => TrashEntry.fromJson(e, dir.path))
          .where((e) => e.key.isNotEmpty)
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      return out;
    } catch (e) {
      debugPrint('TrashManager.list error: $e');
      return <TrashEntry>[];
    }
  }

  /// 還原：[e] 對應嘅 trash 檔 copy 返原路徑；若原路徑唔再存在／寫唔到，
  /// 就用 photo_manager 儲返去相簿。成功之後移除條目。
  static Future<bool> restore(TrashEntry e) async {
    if (kIsWeb) return false;
    try {
      final File f = File(e.filePath);
      if (!await f.exists()) return false;

      bool saved = false;
      // 1) 嘗試還原返原本路徑。
      if (e.originalPath != null && e.originalPath!.isNotEmpty) {
        try {
          final Directory parent =
              Directory(File(e.originalPath!).parent.path);
          if (await parent.exists()) {
            await f.copy(e.originalPath!);
            saved = true;
          }
        } catch (_) {}
      }

      // 2) 後備：儲返去相簿（圖片／影片）。
      if (!saved) {
        if (e.type == 'video') {
          await PhotoManager.editor.saveVideo(
            f,
            title: e.title,
          );
        } else {
          await PhotoManager.editor.saveImageWithPath(
            e.filePath,
            title: e.title,
          );
        }
        saved = true;
      }

      if (saved) {
        // 成功後刪 trash 檔 + 移除條目。
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
        final List<Map<String, dynamic>> entries = await _loadEntries();
        entries.removeWhere((x) => x['key'] == e.key);
        await _saveEntries(entries);
      }
      return saved;
    } catch (err) {
      debugPrint('TrashManager.restore error: $err');
      return false;
    }
  }

  /// 永久刪除單一條目（唔可以還原）。
  static Future<void> removePermanently(TrashEntry e) async {
    try {
      final File f = File(e.filePath);
      if (await f.exists()) await f.delete();
      final List<Map<String, dynamic>> entries = await _loadEntries();
      entries.removeWhere((x) => x['key'] == e.key);
      await _saveEntries(entries);
    } catch (err) {
      debugPrint('TrashManager.removePermanently error: $err');
    }
  }

  /// 清空垃圾桶。
  static Future<void> emptyTrash() async {
    try {
      final List<TrashEntry> all = await list();
      for (final TrashEntry e in all) {
        try {
          final File f = File(e.filePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await _saveEntries(<Map<String, dynamic>>[]);
    } catch (err) {
      debugPrint('TrashManager.emptyTrash error: $err');
    }
  }
}
