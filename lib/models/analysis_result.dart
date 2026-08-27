import 'package:photo_manager/photo_manager.dart';

import 'junk_file.dart';

/// 清理類別：用嚟分類「可釋放空間」嘅統計儀表板。
enum AssetCategory {
  duplicate('重複'),
  similar('相似'),
  blurry('模糊'),
  screenshot('截圖'),
  social('社交'),
  junk('垃圾'),
  large('大檔');

  /// 中文顯示名稱。
  final String label;
  const AssetCategory(this.label);
}

/// 一個相片/影片資產，附上緩存咗嘅檔案大小（bytes）。
class AssetItem {
  final AssetEntity entity;
  final int sizeBytes;

  /// 來源相簿名（社交媒體相片偵測用）。
  final String? albumName;

  /// 分析時填：32x32 灰度方差，越低代表越模糊／低細節。
  double? blurScore;

  /// 分析時填：16x16 灰度平均感知 hash（hex 字串），用嚟偵測相似相片。
  String? grayHash16;

  AssetItem({
    required this.entity,
    required this.sizeBytes,
    this.albumName,
  });

  String get id => entity.id;
  AssetType get type => entity.type;
  bool get isVideo => type == AssetType.video;
  bool get isImage => type == AssetType.image;

  /// 檔名／顯示名（細楷由 caller 自行處理）。
  String get title => entity.title ?? '';

  /// 用寬度 x 高度 + 檔案大小做指紋，用嚟偵測重複相片。
  String get signature => '${entity.width}x${entity.height}_$sizeBytes';

  double get sizeMB => sizeBytes / (1024 * 1024);

  /// 一個「最佳」評分：解析度（width×height）優先，其次係檔案大小。
  /// 用嚟決定每組重複／相似要保留邊張。
  int get bestScore =>
      (entity.width * entity.height) * 1000000000 + sizeBytes;

  @override
  bool operator ==(Object other) => other is AssetItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 重複／相似分組嘅共同邏輯。
abstract class AssetGroupBase {
  List<AssetItem> get items;

  int get count => items.length;
  double get totalMB => items.fold(0.0, (sum, a) => sum + a.sizeMB);

  /// 推薦保留嗰張「最佳」：解析度最高（width*height 最大），平手揀檔案最大。
  AssetItem get bestItem {
    AssetItem best = items.first;
    for (final AssetItem it in items) {
      if (it.bestScore > best.bestScore) best = it;
    }
    return best;
  }

  /// 保留最佳嗰張之後，其餘全部（建議刪除）可釋放嘅 byte 數。
  int get recoverableBytes {
    final AssetItem best = bestItem;
    return items.fold(0, (sum, a) => a == best ? sum : sum + a.sizeBytes);
  }
}

/// 一組判定為重複嘅資產（同指紋，完全重複）。
class DuplicateGroup extends AssetGroupBase {
  final String signature;

  @override
  final List<AssetItem> items;

  DuplicateGroup(this.signature, this.items);
}

/// 一組判定為相似嘅資產（灰度 hash 相似度 > 90%，非完全重複）。
class SimilarGroup extends AssetGroupBase {
  final String resolutionKey;

  @override
  final List<AssetItem> items;

  SimilarGroup(this.resolutionKey, this.items);
}

/// 一次掃描嘅分析結果。
class ScanResult {
  /// 全部 image/video 資產，按 size 由大到細排。
  final List<AssetItem> all;

  /// 重複相片分組（每組 ≥2 張）。
  final List<DuplicateGroup> duplicateGroups;

  /// 相似相片分組（每組 ≥2 張）。
  final List<SimilarGroup> similarGroups;

  /// 大檔案，按 size 由大到細排。
  final List<AssetItem> largeFiles;

  /// 每個類別可釋放嘅 byte 數（互斥，加埋 = totalRecoverableBytes）。
  final Map<AssetCategory, int> categoryBytes;

  /// 掃描到嘅垃圾／快取檔案（獨立分類「垃圾檔」，非相片資產）。
  final List<JunkFile> junkFiles;

  /// 模糊／低細節相片（灰度方差低過閾值）。
  final List<AssetItem> blurryItems;

  /// 截圖（由 filename／title／dimension 偵測）。
  final List<AssetItem> screenshotItems;

  /// 社交媒體相簿／檔名（WhatsApp／Telegram／WeChat／Instagram 等）入面嘅相片。
  final List<AssetItem> socialMediaItems;

  ScanResult({
    required this.all,
    required this.duplicateGroups,
    required this.similarGroups,
    required this.largeFiles,
    required this.categoryBytes,
    this.junkFiles = const <JunkFile>[],
    this.blurryItems = const <AssetItem>[],
    this.screenshotItems = const <AssetItem>[],
    this.socialMediaItems = const <AssetItem>[],
  });

  /// 複製一份並附加垃圾檔案列表。
  ScanResult withJunk(List<JunkFile> junk) => ScanResult(
        all: all,
        duplicateGroups: duplicateGroups,
        similarGroups: similarGroups,
        largeFiles: largeFiles,
        categoryBytes: categoryBytes,
        junkFiles: junk,
        blurryItems: blurryItems,
        screenshotItems: screenshotItems,
        socialMediaItems: socialMediaItems,
      );

  /// 所有垃圾檔案可釋放嘅 byte 數。
  int get junkBytes => junkFiles.fold(0, (sum, j) => sum + j.sizeBytes);

  /// 全部類別可釋放嘅 byte 數總和。
  int get totalRecoverableBytes =>
      categoryBytes.values.fold(0, (sum, v) => sum + v);

  /// 全部資產（體積）加埋嘅 byte 數，用嚟計佔比。
  int get totalLibraryBytes => all.fold(0, (sum, a) => sum + a.sizeBytes);

  /// 所有重複多餘（保留最佳後）可釋放嘅 byte 數。
  int get recoverableDuplicateBytes =>
      duplicateGroups.fold(0, (sum, g) => sum + g.recoverableBytes);
}
