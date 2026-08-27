import 'package:photo_manager/photo_manager.dart';

/// 一個相片/影片資產，附上緩存咗嘅檔案大小（bytes）。
class AssetItem {
  final AssetEntity entity;
  final int sizeBytes;

  AssetItem({required this.entity, required this.sizeBytes});

  String get id => entity.id;
  AssetType get type => entity.type;
  bool get isVideo => type == AssetType.video;
  bool get isImage => type == AssetType.image;

  /// 用寬度 x 高度 + 檔案大小做指紋，用嚟偵測重複相片。
  String get signature => '${entity.width}x${entity.height}_$sizeBytes';

  double get sizeMB => sizeBytes / (1024 * 1024);

  @override
  bool operator ==(Object other) => other is AssetItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 一組判定為重複嘅資產。
class DuplicateGroup {
  final String signature;
  final List<AssetItem> items;

  DuplicateGroup(this.signature, this.items);

  int get count => items.length;
  double get totalMB => items.fold(0, (sum, a) => sum + a.sizeMB);
}

/// 一次掃描嘅分析結果。
class ScanResult {
  /// 全部 image/video 資產，按 size 由大到細排。
  final List<AssetItem> all;

  /// 重複相片分組（每組 ≥2 張）。
  final List<DuplicateGroup> duplicateGroups;

  /// 大檔案，按 size 由大到細排。
  final List<AssetItem> largeFiles;

  ScanResult({
    required this.all,
    required this.duplicateGroups,
    required this.largeFiles,
  });

  /// 所有重複多餘（每組留 1 張後）可釋放嘅 byte 數。
  int get recoverableDuplicateBytes => duplicateGroups.fold(
        0,
        (sum, g) => sum + (g.items.length - 1) * g.items.first.sizeBytes,
      );
}