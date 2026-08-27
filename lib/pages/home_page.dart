import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/analysis_result.dart';
import '../models/junk_file.dart';
import '../services/junk_scanner.dart';
import '../services/photo_scanner.dart';
import '../services/reminder_service.dart';
import '../services/trash_manager.dart';
import '../theme.dart';
import 'trash_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _gridCross = 4;

  bool _scanning = false;
  String? _notice; // 權限被拒 / 出錯提示
  ScanResult? _result;
  Map<String, AssetItem> _selected = <String, AssetItem>{};
  Map<String, JunkFile> _selectedJunk = <String, JunkFile>{};
  int _trashCount = 0;

  int get _selectedBytes =>
      _selected.values.fold(0, (sum, a) => sum + a.sizeBytes);

  int get _junkBytes =>
      _selectedJunk.values.fold(0, (sum, j) => sum + j.sizeBytes);

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    // 初始化提醒服務（每日通知 + 攞權限）。
    await ReminderService.instance.init();
    // 讀取垃圾桶入面有幾多項（AppBar 徽章）。
    final int c = (await TrashManager.list()).length;
    if (!mounted) return;
    setState(() => _trashCount = c);
  }

  Future<void> _onScan() async {
    if (kIsWeb) {
      setState(() {
        _scanning = false;
        _notice = '網頁版冇得讀手機相簿（browser 限制）。請裝 Android APK 先可以掃描相片。';
      });
      return;
    }
    setState(() {
      _scanning = true;
      _notice = null;
    });
    try {
      final bool ok = await PhotoScanner.requestPermission();
      if (!ok) {
        setState(() {
          _scanning = false;
          _notice = '拒絕咗相片權限，未能掃描。請喺系統設定度允許存取相片。';
        });
        return;
      }
      final List<AssetItem> items = await PhotoScanner.scanAllAssets();
      if (items.isEmpty) {
        setState(() {
          _scanning = false;
          _notice = '相簿搵唔到任何相片／影片。請確認相簿有內容，並檢查權限。';
        });
        return;
      }
      final ScanResult result = (await PhotoScanner.analyze(items)).withJunk(
            await JunkScanner.scanJunk(),
          );

      // 預設：每組重複／相似留「最佳」嗰張，其餘勾選為要刪除。
      final Map<String, AssetItem> selection = <String, AssetItem>{};
      for (final AssetGroupBase g in [
        ...result.duplicateGroups,
        ...result.similarGroups,
      ]) {
        for (final AssetItem it in g.items) {
          if (it != g.bestItem) {
            selection[it.id] = it;
          }
        }
      }

      // 掃描完：記錄結果，發現新重複就提醒（每日最多 1 次）。
      await ReminderService.instance.updateAfterScan(result);

      if (!mounted) return;
      setState(() {
        _result = result;
        _selected = selection;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _notice = '掃描時出錯：$e';
      });
    }
  }

  void _toggle(AssetItem item, bool value) {
    setState(() {
      if (value) {
        _selected[item.id] = item;
      } else {
        _selected.remove(item.id);
      }
    });
  }

  /// 「保留最佳」：將某組重複／相似嘅揀選重置 —— 留最佳嗰張，揀晒其餘。
  void _keepBest(AssetGroupBase g) {
    setState(() {
      final AssetItem best = g.bestItem;
      for (final AssetItem it in g.items) {
        if (it == best) {
          _selected.remove(it.id);
        } else {
          _selected[it.id] = it;
        }
      }
    });
  }

  void _toggleJunk(JunkFile file, bool value) {
    setState(() {
      if (value) {
        _selectedJunk[file.id] = file;
      } else {
        _selectedJunk.remove(file.id);
      }
    });
  }

  Future<void> _openTrash() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TrashPage()),
    );
    if (!mounted) return;
    final int c = (await TrashManager.list()).length;
    setState(() => _trashCount = c);
  }

  Future<void> _onDelete() async {
    final List<AssetItem> assetItems = _selected.values.toList();
    final List<JunkFile> junkItems = _selectedJunk.values.toList();
    if (assetItems.isEmpty && junkItems.isEmpty) return;

    final int totalBytes = _selectedBytes + _junkBytes;
    final int totalCount = assetItems.length + junkItems.length;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('確認刪除'),
        content: Text(
          '將刪除 $totalCount 項檔案，可騰出 ${formatBytes(totalBytes)} 嘅空間。\n\n'
          '相片／影片會先備份去「垃圾桶」，刪咗都可以隨時還原；'
          '垃圾／快取檔就會直接刪走。',
          style: const TextStyle(color: AppColors.text, fontSize: 14.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _scanning = true);

    // 1) 垃圾／快取檔：直接刪除。
    int junkDeleted = 0;
    if (junkItems.isNotEmpty) {
      junkDeleted = await JunkScanner.deleteJunkFiles(junkItems);
    }

    // 2) 相片／影片：先 copy 去垃圾桶（copy 成功先刪原檔）。
    int trashed = 0;
    for (final AssetItem a in assetItems) {
      if (await TrashManager.backup(a)) trashed++;
    }
    final List<String> ids = assetItems.map((a) => a.id).toList();
    final List<String> undeleted = await PhotoScanner.deleteByIds(ids);
    final int deletedAssets = ids.length - undeleted.length;

    if (!mounted) return;
    final int totalDeleted = junkDeleted + deletedAssets;
    setState(() {
      _scanning = false;
      _selected = <String, AssetItem>{};
      _selectedJunk = <String, JunkFile>{};
      _notice = totalDeleted > 0
          ? '已刪 $totalDeleted 項 · 可還原'
          : '未能刪除任何檔案，請檢查權限。';
      if (trashed > 0) _trashCount += trashed;
      if (totalDeleted > 0) {
        _rescanAfterDelete();
      }
    });

    // 刪完彈提示，附「垃圾桶」捷徑。
    if (mounted && trashed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已刪 $totalDeleted 項 · $trashed 項可喺垃圾桶還原'),
          backgroundColor: AppColors.success,
          action: SnackBarAction(
            label: '垃圾桶',
            textColor: Colors.white,
            onPressed: _openTrash,
          ),
        ),
      );
    }
  }

  Future<void> _rescanAfterDelete() async {
    try {
      final List<AssetItem> items = await PhotoScanner.scanAllAssets();
      final ScanResult result = (await PhotoScanner.analyze(items)).withJunk(
            await JunkScanner.scanJunk(),
          );
      final Map<String, AssetItem> selection = <String, AssetItem>{};
      for (final AssetGroupBase g in [
        ...result.duplicateGroups,
        ...result.similarGroups,
      ]) {
        for (final AssetItem it in g.items) {
          if (it != g.bestItem) {
            selection[it.id] = it;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _selected = selection;
        _selectedJunk = <String, JunkFile>{};
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '重新掃描失敗：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final int totalCount = _selected.length + _selectedJunk.length;
    final int totalBytes = _selectedBytes + _junkBytes;
    return Scaffold(
      appBar: AppBar(
        title: const Padding(
          padding: EdgeInsets.only(left: 8),
          child: Text('相片清理'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: '垃圾桶',
              icon: Badge(
                isLabelVisible: _trashCount > 0,
                label: Text('$_trashCount'),
                child: const Icon(Icons.delete_sweep_outlined),
              ),
              onPressed: _openTrash,
            ),
          ),
        ],
      ),
      bottomNavigationBar: _result == null
          ? null
          : _BottomDeleteBar(
              count: totalCount,
              freedMB: formatBytes(totalBytes),
              onPressed: totalCount > 0 ? _onDelete : null,
            ),
      body: SafeArea(
        child: _result == null
            ? _buildIntro()
            : _buildResult(),
      ),
    );
  }

  Widget _buildIntro() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '騰出空間，\n執走重複同大檔案。',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '掃描會分析全部相簿，搵出重複相片同佔最多空間嘅相片／影片。',
            style: TextStyle(color: AppColors.caption, fontSize: 14),
          ),
          const SizedBox(height: 40),
          if (_notice != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _notice!,
                style: const TextStyle(color: AppColors.text, fontSize: 13),
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              onPressed: _scanning ? null : _onScan,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: _scanning
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.radar_outlined, size: 22),
                        SizedBox(width: 10),
                        Text('掃描'),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '只需一次，即刻睇到分析結果同可釋放空間。',
            style: TextStyle(color: AppColors.caption, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final ScanResult r = _result!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 頂部「空間儀表板」：可釋放總量 + 圓環 + 各類別色塊。
        _SpaceDashboard(result: r),
        Expanded(
          child: _ResultTabs(
            result: r,
            selected: _selected,
            onToggle: _toggle,
            selectedJunk: _selectedJunk,
            onToggleJunk: _toggleJunk,
            onKeepBest: _keepBest,
          ),
        ),
      ],
    );
  }
}

/// 頂部「空間儀表板」：可釋放總量（大數字）+ 圓環進度 + 各類別色塊。
class _SpaceDashboard extends StatelessWidget {
  final ScanResult result;
  const _SpaceDashboard({required this.result});

  @override
  Widget build(BuildContext context) {
    final int total = result.totalRecoverableBytes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '可釋放空間',
                        style: TextStyle(
                          color: AppColors.caption,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatBytes(total),
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '共 ${result.all.length} 項資產 · '
                        '${result.duplicateGroups.length} 組重複 · '
                        '${result.similarGroups.length} 組相似',
                        style: const TextStyle(
                          color: AppColors.caption,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _Donut(result: result),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final AssetCategory c in AssetCategory.values)
                  _CategoryChip(
                    category: c,
                    bytes: result.categoryBytes[c] ?? 0,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 圓環進度：用 CustomPaint 畫各類別 MB 佔比。
class _Donut extends StatelessWidget {
  final ScanResult result;
  const _Donut({required this.result});

  @override
  Widget build(BuildContext context) {
    final int total = result.totalRecoverableBytes;
    final int lib = result.totalLibraryBytes;
    final int pct = lib > 0 ? ((total / lib) * 100).round() : 0;
    return SizedBox(
      width: 104,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(104, 104),
            painter: _DonutPainter(categoryBytes: result.categoryBytes),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pct%',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Text(
                '可釋放',
                style: TextStyle(
                  color: AppColors.caption,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final Map<AssetCategory, int> categoryBytes;
  _DonutPainter({required this.categoryBytes});

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 13;
    final Offset center = size.center(Offset.zero);
    final double radius = (size.shortestSide - stroke) / 2;

    // 底色軌道。
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AppColors.card;
    canvas.drawCircle(center, radius, track);

    final int total = categoryBytes.values.fold(0, (s, v) => s + v);
    if (total <= 0) return;

    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    double start = -math.pi / 2;
    for (final AssetCategory c in AssetCategory.values) {
      final int bytes = categoryBytes[c] ?? 0;
      if (bytes <= 0) continue;
      final double sweep = (bytes / total) * 2 * math.pi;
      final double gap = sweep > 0.06 ? 0.03 : 0.0;
      final Paint p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = AppColors.categoryColor(c);
      canvas.drawArc(rect, start + gap / 2, sweep - gap, false, p);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.categoryBytes != categoryBytes;
}

/// 一個類別色塊：色點 + 名稱 + MB。
class _CategoryChip extends StatelessWidget {
  final AssetCategory category;
  final int bytes;
  const _CategoryChip({required this.category, required this.bytes});

  @override
  Widget build(BuildContext context) {
    final bool zero = bytes <= 0;
    final Color dotColor = zero
        ? AppColors.caption.withOpacity(0.35)
        : AppColors.categoryColor(category);
    final Color textColor = zero ? AppColors.caption : AppColors.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            category.label,
            style: TextStyle(
              color: textColor,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            formatBytes(bytes),
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultTabs extends StatelessWidget {
  final ScanResult result;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  final Map<String, JunkFile> selectedJunk;
  final void Function(JunkFile, bool) onToggleJunk;
  final void Function(AssetGroupBase) onKeepBest;
  const _ResultTabs({
    required this.result,
    required this.selected,
    required this.onToggle,
    required this.selectedJunk,
    required this.onToggleJunk,
    required this.onKeepBest,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TabBar(
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x11000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                labelColor: AppColors.text,
                unselectedLabelColor: AppColors.caption,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: '全部 ${result.all.length}'),
                  Tab(text: '重複 ${result.duplicateGroups.length}'),
                  Tab(text: '相似 ${result.similarGroups.length}'),
                  Tab(text: '模糊 ${result.blurryItems.length}'),
                  Tab(text: '截圖 ${result.screenshotItems.length}'),
                  Tab(text: '社交 ${result.socialMediaItems.length}'),
                  Tab(text: '大檔案 ${result.largeFiles.length}'),
                  Tab(text: '垃圾檔 ${result.junkFiles.length}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TabBarView(
              children: [
                _ThumbGrid(
                  items: result.all,
                  selected: selected,
                  onToggle: onToggle,
                  emptyMessage: '冇任何相片或影片。',
                ),
                _GroupTab(
                  groups: result.duplicateGroups,
                  emptyMessage: '搵唔到重複相片 👍',
                  selected: selected,
                  onToggle: onToggle,
                  onKeepBest: onKeepBest,
                ),
                _GroupTab(
                  groups: result.similarGroups,
                  emptyMessage: '搵唔到相似相片 👍',
                  selected: selected,
                  onToggle: onToggle,
                  onKeepBest: onKeepBest,
                ),
                _ThumbGrid(
                  items: result.blurryItems,
                  selected: selected,
                  onToggle: onToggle,
                  emptyMessage: '冇發現模糊相片 👍',
                ),
                _ThumbGrid(
                  items: result.screenshotItems,
                  selected: selected,
                  onToggle: onToggle,
                  emptyMessage: '冇發現截圖 👍',
                ),
                _ThumbGrid(
                  items: result.socialMediaItems,
                  selected: selected,
                  onToggle: onToggle,
                  emptyMessage: '冇發現社交媒體相片 👍',
                ),
                _ThumbGrid(
                  items: result.largeFiles,
                  selected: selected,
                  onToggle: onToggle,
                  emptyMessage: '冇大過 20MB 嘅檔案，好好呀 👍',
                ),
                _JunkTab(
                  files: result.junkFiles,
                  selected: selectedJunk,
                  onToggle: onToggleJunk,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 垃圾檔分頁：列出可清嘅快取／垃圾檔案，可逐個勾選。
class _JunkTab extends StatelessWidget {
  final List<JunkFile> files;
  final Map<String, JunkFile> selected;
  final void Function(JunkFile, bool) onToggle;
  const _JunkTab({
    required this.files,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const Center(
        child: Text(
          '搵唔到垃圾檔，好乾淨 👍',
          style: TextStyle(color: AppColors.caption, fontSize: 14),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final JunkFile f = files[i];
        final bool isSel = selected.containsKey(f.id);
        return GestureDetector(
          onTap: () => onToggle(f, !isSel),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: isSel
                  ? Border.all(color: AppColors.accent, width: 2)
                  : Border.all(color: Colors.transparent),
            ),
            child: Row(
              children: [
                Icon(
                  f.ext == '.apk'
                      ? Icons.android_outlined
                      : Icons.description_outlined,
                  color: AppColors.accent,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${f.category} · ${formatBytes(f.sizeBytes)}',
                        style: const TextStyle(
                            color: AppColors.caption, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSel ? AppColors.success : Colors.white,
                    border: Border.all(
                      color: isSel ? AppColors.success : AppColors.caption,
                    ),
                  ),
                  child: isSel
                      ? const Icon(Icons.check, color: Colors.white, size: 16)
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 單格方形縮圖，揀選時有綠 ✓ 圓章 + 亮色邊框。
class _SelectableThumb extends StatelessWidget {
  final AssetItem item;
  final bool isSelected;
  final bool isKept;
  final ValueChanged<bool> onToggle;
  const _SelectableThumb({
    required this.item,
    required this.isSelected,
    required this.onToggle,
    this.isKept = false,
  });

  Future<Uint8List?> _thumb() {
    // 攞真縮圖（約畀 grid 格用嘅解像度）。
    return item.entity.thumbnailDataWithSize(const ThumbnailSize(360, 360));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (isKept) return;
        onToggle(!isSelected);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _thumb(),
              builder: (context, snap) {
                final data = snap.data;
                if (data == null) {
                  return Container(
                    color: AppColors.card,
                    alignment: Alignment.center,
                    child: Icon(
                      item.isVideo
                          ? Icons.movie_outlined
                          : Icons.image_outlined,
                      color: AppColors.caption,
                      size: 30,
                    ),
                  );
                }
                return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
              },
            ),
            // 影片標記。
            if (item.isVideo)
              const Positioned(
                left: 6,
                bottom: 6,
                child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 22),
              )
            else if (item.type == AssetType.image)
              Positioned(
                left: 6,
                bottom: 6,
                child: Text(
                  formatBytes(item.sizeBytes),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                  ),
                ),
              ),
            // 揀選邊框（亮色）／未揀選淡淡框。
            if (isSelected)
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.accent, width: 3.5),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                ),
              )
            else if (!isKept)
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0x22000000), width: 1),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                ),
              ),
            // 右上角狀態圓章。
            Positioned(
              top: 5,
              right: 5,
              child: isKept
                  ? _badge(
                      color: Colors.black45,
                      border: Colors.white,
                      icon: Icons.bookmark,
                      size: 12,
                    )
                  : isSelected
                      ? _badge(
                          color: AppColors.success,
                          border: Colors.white,
                          icon: Icons.check,
                          size: 12,
                        )
                      : _badge(
                          color: Colors.black26,
                          border: Colors.white,
                          icon: Icons.add,
                          size: 12,
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge({
    required Color color,
    required Color border,
    required IconData icon,
    required double size,
  }) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 2),
      ),
      child: Icon(icon, color: Colors.white, size: size),
    );
  }
}

/// 通用大縮圖 grid（跳選模式）。
class _ThumbGrid extends StatelessWidget {
  final List<AssetItem> items;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  final String emptyMessage;
  const _ThumbGrid({
    required this.items,
    required this.selected,
    required this.onToggle,
    required this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          emptyMessage,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.caption, fontSize: 14),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _HomePageState._gridCross,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return _SelectableThumb(
          item: item,
          isSelected: selected.containsKey(item.id),
          onToggle: (v) => onToggle(item, v),
        );
      },
    );
  }
}

/// 重複／相似分頁：每組一行縮圖，留「最佳」其餘預設揀選，可「✨ 保留最佳」。
class _GroupTab extends StatelessWidget {
  final List<AssetGroupBase> groups;
  final String emptyMessage;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  final void Function(AssetGroupBase) onKeepBest;
  const _GroupTab({
    required this.groups,
    required this.emptyMessage,
    required this.selected,
    required this.onToggle,
    required this.onKeepBest,
  });

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return Center(
        child: Text(
          emptyMessage,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.caption, fontSize: 14),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final AssetGroupBase g = groups[i];
        final String word = g is SimilarGroup ? '相似' : '重複';
        return _GroupCard(
          title: '${g.count} 張$word · ${formatBytes(g.totalMB)}',
          group: g,
          selected: selected,
          onToggle: onToggle,
          onKeepBest: () => onKeepBest(g),
        );
      },
    );
  }
}

/// 單組重複／相似卡片：標示「最佳」保留嗰張，其餘可刪。
/// 「✨ 保留最佳」掣：撳完自動留最佳、揀晒該組其餘全部。
class _GroupCard extends StatelessWidget {
  final String title;
  final AssetGroupBase group;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  final VoidCallback onKeepBest;
  const _GroupCard({
    required this.title,
    required this.group,
    required this.selected,
    required this.onToggle,
    required this.onKeepBest,
  });

  @override
  Widget build(BuildContext context) {
    final AssetItem best = group.bestItem;
    final int delCount = group.count - 1;
    final int delBytes = group.recoverableBytes;
    final double cell =
        (MediaQuery.of(context).size.width - 16 * 2 - 6 * (group.count - 1)) /
            group.count;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '删 $delCount 張 · 可騰 ${formatBytes(delBytes)}',
                    style: const TextStyle(
                      color: AppColors.success,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onKeepBest,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    icon: const Icon(Icons.auto_awesome, size: 13),
                    label: const Text('保留最佳'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: cell,
            child: Row(
              children: [
                for (int k = 0; k < group.items.length; k++) ...[
                  if (k > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _SelectableThumb(
                      item: group.items[k],
                      isKept: group.items[k] == best,
                      isSelected: selected.containsKey(group.items[k].id),
                      onToggle: (v) => onToggle(group.items[k], v),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomDeleteBar extends StatelessWidget {
  final int count;
  final String freedMB;
  final VoidCallback? onPressed;
  const _BottomDeleteBar({
    required this.count,
    required this.freedMB,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E5EA))),
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '已揀選 $count 項',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  freedMB,
                  style: const TextStyle(color: AppColors.caption, fontSize: 12.5),
                ),
              ],
            ),
            const Spacer(),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  disabledBackgroundColor: const Color(0xFFE0E0E5),
                  disabledForegroundColor: AppColors.caption,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                icon: const Icon(Icons.delete_outline, size: 20),
                label: const Text('刪除已揀'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 格式化 bytes 做易讀 MB。
String formatBytes(num bytes) {
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}