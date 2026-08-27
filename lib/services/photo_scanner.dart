import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';

import '../models/analysis_result.dart';

/// 用 photo_manager 掃描全部相簿資產，再用 image 庫做模糊／相似偵測。
class PhotoScanner {
  PhotoScanner._();

  /// 大於等於依個大小先當做「大檔案」（MB）。
  static const double largeFileThresholdMB = 20;

  /// 細過依個大小就當做「垃圾」小檔（bytes）。
  static const int junkThresholdBytes = 100 * 1024;

  /// 32x32 灰度方差低過呢個值就當做「模糊／低細節」。
  static const double blurVarianceThreshold = 40;

  /// 16x16 灰度 hash 相似度 ≥ 呢個值（0-1）就當做「相似相片」。
  static const double similarThreshold = 0.90;

  /// 社交媒體相簿關鍵字（細楷比對）。
  static const List<String> socialAlbumKeywords = <String>[
    'whatsapp',
    'telegram',
    'wechat',
    '微信',
    'instagram',
  ];

  /// 截圖 filename / title 關鍵字（細楷比對）。
  static const List<String> screenshotKeywords = <String>[
    'screenshot',
    'screen shot',
    'screen_shot',
    '截圖',
    '螢幕擷取',
    '屏幕截图',
    'スクリーンショット',
    '스크린샷',
    'captura',
  ];

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
        byId[e.id] = AssetItem(
          entity: e,
          sizeBytes: sizeBytes,
          albumName: path.name,
        );
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

  /// 完整分析：逐張圖片攞細縮圖 → 計模糊分數 + 灰度 hash → 再分組。
  static Future<ScanResult> analyze(List<AssetItem> items) async {
    for (final AssetItem it in items) {
      if (it.type != AssetType.image) continue;
      final Uint8List? thumb = await _safeThumb(it);
      if (thumb == null) continue;
      final ({double blurScore, String hashHex})? a = _analyzePixels(thumb);
      if (a == null) continue;
      it.blurScore = a.blurScore;
      it.grayHash16 = a.hashHex;
    }
    return buildResult(items);
  }

  static Future<Uint8List?> _safeThumb(AssetItem it) async {
    try {
      // 細縮圖就夠分析用（16x16 hash / 32x32 方差），快好多。
      return await it.entity.thumbnailDataWithSize(const ThumbnailSize(128, 128));
    } catch (_) {
      return null;
    }
  }

  /// 由縮圖計出模糊分數（32x32 灰度方差）同感知 hash（16x16 灰度平均 hash）。
  static ({double blurScore, String hashHex})? _analyzePixels(Uint8List bytes) {
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    // 模糊分數：32x32 灰度方差（低方差 = 模糊／低細節）。
    final img.Image gray32 =
        img.grayscale(img.copyResize(decoded, width: 32, height: 32));
    final List<double> lum = <double>[];
    for (final img.Pixel p in gray32) {
      lum.add((p.r + p.g + p.b) / 3.0);
    }
    final double mean = lum.reduce((a, b) => a + b) / lum.length;
    double variance = 0;
    for (final double v in lum) {
      variance += (v - mean) * (v - mean);
    }
    variance /= lum.length;

    // 感知 hash：16x16 灰度，像素 ≥ 平均 bit = 1，pack 做 hex。
    final img.Image gray16 =
        img.grayscale(img.copyResize(decoded, width: 16, height: 16));
    final List<int> vals = <int>[];
    int sum = 0;
    for (final img.Pixel p in gray16) {
      final int v = ((p.r + p.g + p.b) / 3).round();
      vals.add(v);
      sum += v;
    }
    final double avg = sum / vals.length;
    final StringBuffer sb = StringBuffer();
    int nibble = 0;
    for (int i = 0; i < vals.length; i++) {
      nibble = (nibble << 1) | (vals[i] >= avg ? 1 : 0);
      if (i % 4 == 3) {
        sb.write(nibble.toRadixString(16));
        nibble = 0;
      }
    }

    return (blurScore: variance, hashHex: sb.toString());
  }

  /// 由原始資產組裝分析結果（含類別統計 + 重複／相似分組）。
  /// 需要先 run [`analyze`] 先至有 blurScore / grayHash16 填好。
  static ScanResult buildResult(List<AssetItem> items) {
    items.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));

    // 1) 完全重複：相同指紋（解像度 + sizeBytes）。
    final Map<String, List<AssetItem>> groups = <String, List<AssetItem>>{};
    for (final AssetItem it in items) {
      groups.putIfAbsent(it.signature, () => <AssetItem>[]).add(it);
    }
    final List<DuplicateGroup> dupGroups = groups.values
        .where((g) => g.length > 1)
        .map((g) => DuplicateGroup(g.first.signature, g))
        .toList()
      ..sort((a, b) => b.totalMB.compareTo(a.totalMB));
    final Set<String> dupIds = dupGroups
        .expand((g) => g.items.map((it) => it.id))
        .toSet();

    // 2) 相似（非 exact）：同 size bucket 內用灰度 hash 兩兩比對，相似 >90%。
    final List<SimilarGroup> simGroups = _groupSimilarByHash(items, dupIds);

    // 3) 大檔案。
    final List<AssetItem> large = items
        .where((it) => it.sizeMB >= largeFileThresholdMB)
        .toList();

    // 4) 模糊：灰度方差低過閾值。
    final List<AssetItem> blurry = items
        .where((it) =>
            it.blurScore != null && it.blurScore! < blurVarianceThreshold)
        .toList();

    // 5) 截圖：filename/title/dimension。
    final List<AssetItem> screenshots =
        items.where(_isScreenshot).toList();

    // 6) 社交媒體：相簿名／檔名含社交 app 關鍵字。
    final List<AssetItem> social = items.where(_isSocial).toList();

    // 7) 類別統計（互斥，優先序：重複 > 相似 > 模糊 > 截圖 > 社交 > 垃圾 > 大檔）。
    final Map<AssetCategory, int> catBytes = <AssetCategory, int>{
      for (final AssetCategory c in AssetCategory.values) c: 0,
    };
    final Set<String> simIds = simGroups
        .expand((g) => g.items.map((it) => it.id))
        .toSet();
    final Set<String> blurIds = blurry.map((it) => it.id).toSet();
    for (final DuplicateGroup g in dupGroups) {
      catBytes[AssetCategory.duplicate] =
          catBytes[AssetCategory.duplicate]! + g.recoverableBytes;
    }
    for (final SimilarGroup g in simGroups) {
      catBytes[AssetCategory.similar] =
          catBytes[AssetCategory.similar]! + g.recoverableBytes;
    }
    for (final AssetItem it in items) {
      if (dupIds.contains(it.id) || simIds.contains(it.id)) continue;
      if (blurIds.contains(it.id)) {
        catBytes[AssetCategory.blurry] =
            catBytes[AssetCategory.blurry]! + it.sizeBytes;
      } else if (_isScreenshot(it)) {
        catBytes[AssetCategory.screenshot] =
            catBytes[AssetCategory.screenshot]! + it.sizeBytes;
      } else if (_isSocial(it)) {
        catBytes[AssetCategory.social] =
            catBytes[AssetCategory.social]! + it.sizeBytes;
      } else if (it.sizeBytes < junkThresholdBytes) {
        catBytes[AssetCategory.junk] =
            catBytes[AssetCategory.junk]! + it.sizeBytes;
      } else if (it.sizeMB >= largeFileThresholdMB) {
        catBytes[AssetCategory.large] =
            catBytes[AssetCategory.large]! + it.sizeBytes;
      }
    }

    return ScanResult(
      all: items,
      duplicateGroups: dupGroups,
      similarGroups: simGroups,
      largeFiles: large,
      categoryBytes: catBytes,
      blurryItems: blurry,
      screenshotItems: screenshots,
      socialMediaItems: social,
    );
  }

  /// 相似分組：用 sizeBytes ~/ 1024（近似大小）做 bucket，bucket 內兩兩
  /// 比較 16x16 灰度 hash，相似度 ≥ similarThreshold 就 union 埋一組。
  /// exact 重複嗰啲會排除，等「相似」tab 唔會同「重複」重複。
  static List<SimilarGroup> _groupSimilarByHash(
    List<AssetItem> items,
    Set<String> dupIds,
  ) {
    final Map<int, List<AssetItem>> buckets = <int, List<AssetItem>>{};
    for (final AssetItem it in items) {
      if (dupIds.contains(it.id)) continue;
      if (!it.isImage) continue;
      if (it.grayHash16 == null) continue;
      if (it.sizeBytes < junkThresholdBytes) continue; // 細 icon 唔當相似
      buckets.putIfAbsent(it.sizeBytes ~/ 1024, () => <AssetItem>[]).add(it);
    }

    final List<SimilarGroup> result = <SimilarGroup>[];
    for (final List<AssetItem> bucket in buckets.values) {
      if (bucket.length < 2) continue;
      // union-find
      final Map<String, String> parent = <String, String>{};
      String find(String x) {
        parent.putIfAbsent(x, () => x);
        while (parent[x] != x) {
          parent[x] = parent[parent[x]]!;
          x = parent[x]!;
        }
        return x;
      }

      void union(String a, String b) {
        final String ra = find(a);
        final String rb = find(b);
        if (ra != rb) parent[ra] = rb;
      }

      for (int i = 0; i < bucket.length; i++) {
        for (int j = i + 1; j < bucket.length; j++) {
          if (_hashSimilarity(bucket[i].grayHash16!, bucket[j].grayHash16!) >=
              similarThreshold) {
            union(bucket[i].id, bucket[j].id);
          }
        }
      }

      final Map<String, List<AssetItem>> byRoot = <String, List<AssetItem>>{};
      for (final AssetItem it in bucket) {
        byRoot.putIfAbsent(find(it.id), () => <AssetItem>[]).add(it);
      }
      for (final List<AssetItem> g in byRoot.values) {
        if (g.length > 1) {
          result.add(
            SimilarGroup(
              '${g.first.entity.width}x${g.first.entity.height}',
              g,
            ),
          );
        }
      }
    }
    result.sort((a, b) => b.totalMB.compareTo(a.totalMB));
    return result;
  }

  /// 兩個 hex hash 嘅相似度（0-1）：逐 nibble 計漢明距離。
  static double _hashSimilarity(String a, String b) {
    if (a.length != b.length || a.isEmpty) return 0;
    int sameBits = 0;
    for (int i = 0; i < a.length; i++) {
      final int x = int.parse(a[i], radix: 16);
      final int y = int.parse(b[i], radix: 16);
      sameBits += 4 - _popcount(x ^ y);
    }
    return sameBits / (a.length * 4);
  }

  static int _popcount(int v) {
    int c = 0;
    while (v > 0) {
      c += v & 1;
      v >>= 1;
    }
    return c;
  }

  /// 截圖偵測：filename/title 關鍵字、iOS IMG_*.PNG 慣例、超長窄比例。
  static bool _isScreenshot(AssetItem it) {
    final String t = it.title.toLowerCase();
    for (final String k in screenshotKeywords) {
      if (t.contains(k)) return true;
    }
    // iOS 截圖通常叫 IMG_xxxx.PNG（相機相係 HEIC/JPG）。
    if (t.startsWith('img_') && t.endsWith('.png')) return true;
    // dimension 特徵：比例 ≥ 2.2:1 或 ≤ 1:2.2 多數係截圖／長圖。
    if (it.isImage && it.entity.width > 0 && it.entity.height > 0) {
      final double ratio = it.entity.width / it.entity.height;
      if (ratio >= 2.2 || ratio <= 1 / 2.2) return true;
    }
    return false;
  }

  /// 社交媒體相片：相簿名或檔名含 WhatsApp／Telegram／WeChat／Instagram 等。
  static bool _isSocial(AssetItem it) {
    final String album = (it.albumName ?? '').toLowerCase();
    final String title = it.title.toLowerCase();
    for (final String k in socialAlbumKeywords) {
      if (album.contains(k) || title.contains(k)) return true;
    }
    return false;
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
