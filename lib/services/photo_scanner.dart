import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/analysis_result.dart';

/// 用 photo_manager 掃描全部相簿資產。
class PhotoScanner {
  PhotoScanner._();

  /// 大於等於依個大小先當做「大檔案」（MB）。
  static const double largeFileThresholdMB = 20;

  /// 攞權限（Android 13+ 由 photo_manager 自動處理）。
  /// 傳返 `true` 表示已授權（authorized / limited）。
  static Future<bool> requestPermission() async {
    final PermissionState state =
        await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  /// 掃描全部相簿，只留 image / video 資產，按 id 去重。
  static Future<List<AssetItem>> scanAllAssets() async {
    final List<AssetPathEntity> paths =
        await PhotoManager.getAssetPathList(type: RequestType.common);
    final Map<String, AssetItem> byId = <String, AssetItem>{};
    for (final AssetPathEntity path in paths) {
      final int count = await path.assetCountAsync;
      if (count == 0) continue;
      final List<AssetEntity> entities =
          await path.getAssetListRange(start: 0, end: count);
      for (final AssetEntity e in entities) {
        if (e.type != AssetType.image && e.type != AssetType.video) continue;
        if (byId.containsKey(e.id)) continue;
        final int sizeBytes = await _safeFileSize(e);
        byId[e.id] = AssetItem(entity: e, sizeBytes: sizeBytes);
      }
    }
    return byId.values.toList();
  }

  static Future<int> _safeFileSize(AssetEntity e) async {
    try {
      return await e.fileSize;
    } catch (_) {
      return 0;
    }
  }

  /// 由原始資產組裝分析結果。
  static ScanResult buildResult(List<AssetItem> items) {
    items.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));

    final Map<String, List<AssetItem>> groups = <String, List<AssetItem>>{};
    for (final AssetItem it in items) {
      groups.putIfAbsent(it.signature, () => <AssetItem>[]).add(it);
    }
    final List<DuplicateGroup> dupGroups = groups.values
        .where((g) => g.length > 1)
        .map((g) => DuplicateGroup(g.first.signature, g))
        .toList()
      ..sort((a, b) => b.totalMB.compareTo(a.totalMB));

    final List<AssetItem> large = items
        .where((it) => it.sizeMB >= largeFileThresholdMB)
        .toList();

    return ScanResult(all: items, duplicateGroups: dupGroups, largeFiles: large);
  }

  /// 用 id 直接執行刪除（Android 需要可管理媒體權限）。
  /// 傳返未成功刪除嘅 id。
  static Future<List<String>> deleteByIds(List<String> ids) async {
    try {
      return await PhotoManager.editor.deleteWithIds(ids);
    } catch (e) {
      debugPrint('PhotoScanner.deleteByIds error: $e');
      return ids;
    }
  }
}