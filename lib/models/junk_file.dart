/// 一個垃圾／快取檔案（例如 .apk、.tmp、.log、快取檔）。
class JunkFile {
  /// 檔案絕對路徑（同時做唯一 id）。
  final String path;

  /// 檔名。
  final String name;

  /// 大小（bytes）。
  final int sizeBytes;

  /// 類別標籤（例如「快取」「下載垃圾」）。
  final String category;

  /// 副檔名（冇就空字串）。
  final String ext;

  JunkFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.category,
    required this.ext,
  });

  String get id => path;

  double get sizeMB => sizeBytes / (1024 * 1024);

  @override
  bool operator ==(Object other) => other is JunkFile && other.path == path;

  @override
  int get hashCode => path.hashCode;
}
