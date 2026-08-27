import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/analysis_result.dart';
import '../services/photo_scanner.dart';
import '../theme.dart';

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

  int get _selectedBytes =>
      _selected.values.fold(0, (sum, a) => sum + a.sizeBytes);

  Future<void> _onScan() async {
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
      final ScanResult result = PhotoScanner.buildResult(items);

      // 預設：每組重複留 1 張，其餘勾選為要刪除。
      final Map<String, AssetItem> selection = <String, AssetItem>{};
      for (final DuplicateGroup g in result.duplicateGroups) {
        for (final AssetItem it in g.items.skip(1)) {
          selection[it.id] = it;
        }
      }

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

  Future<void> _onDelete() async {
    if (_selected.isEmpty) return;
    final int totalBytes = _selectedBytes;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('確認刪除'),
        content: Text(
          '將刪除 ${_selected.length} 項檔案，可騰出 ${formatBytes(totalBytes)} 嘅空間。\n\n'
          '此操作會將相片／影片放入（Android）垃圾桶／永久移除，請確認。',
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
    final List<String> ids = _selected.keys.toList();
    final List<String> undeleted = await PhotoScanner.deleteByIds(ids);
    if (!mounted) return;
    final int deletedCount = ids.length - undeleted.length;
    setState(() {
      _scanning = false;
      _selected = <String, AssetItem>{};
      _notice = deletedCount > 0
          ? '已刪除 $deletedCount 項，騰出約 ${formatBytes(totalBytes)} 空間。'
          : '未能刪除任何檔案，請檢查權限。';
      if (deletedCount > 0) {
        _rescanAfterDelete();
      }
    });
  }

  Future<void> _rescanAfterDelete() async {
    try {
      final List<AssetItem> items = await PhotoScanner.scanAllAssets();
      final ScanResult result = PhotoScanner.buildResult(items);
      final Map<String, AssetItem> selection = <String, AssetItem>{};
      for (final DuplicateGroup g in result.duplicateGroups) {
        for (final AssetItem it in g.items.skip(1)) {
          selection[it.id] = it;
        }
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _selected = selection;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = '重新掃描失敗：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Padding(
          padding: EdgeInsets.only(left: 8),
          child: Text('相片清理'),
        ),
      ),
      bottomNavigationBar: _result == null
          ? null
          : _BottomDeleteBar(
              count: _selected.length,
              freedMB: formatBytes(_selectedBytes),
              onPressed: _selected.isNotEmpty ? _onDelete : null,
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
    final int dupeExtra = r.duplicateGroups
        .fold(0, (sum, g) => sum + (g.count - 1));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 空間統計細字放頂。
        _SpaceStats(result: r, selectedBytes: _selectedBytes, dupeExtra: dupeExtra),
        Expanded(
          child: _ResultTabs(
            result: r,
            selected: _selected,
            onToggle: _toggle,
          ),
        ),
      ],
    );
  }
}

/// 頂部一行細細嘅空間統計。
class _SpaceStats extends StatelessWidget {
  final ScanResult result;
  final int selectedBytes;
  final int dupeExtra;
  const _SpaceStats({
    required this.result,
    required this.selectedBytes,
    required this.dupeExtra,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          _Chip(icon: Icons.photo_library_outlined, text: '${result.all.length} 項'),
          const SizedBox(width: 10),
          _Chip(
            icon: Icons.content_copy_outlined,
            text: '重複多餘 $dupeExtra',
          ),
          const SizedBox(width: 10),
          _Chip(
            icon: Icons.insights_outlined,
            text: '可騰 ${formatBytes(result.recoverableDuplicateBytes)}',
            emphasize: true,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool emphasize;
  const _Chip({required this.icon, required this.text, this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    final Color color = emphasize ? AppColors.success : AppColors.caption;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
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
  const _ResultTabs({
    required this.result,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
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
                  fontSize: 13.5,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13.5,
                ),
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                tabs: [
                  Tab(text: '全部 ${result.all.length}'),
                  Tab(text: '重複 ${result.duplicateGroups.length}'),
                  Tab(text: '大檔案 ${result.largeFiles.length}'),
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
                _DuplicateTab(
                  groups: result.duplicateGroups,
                  selected: selected,
                  onToggle: onToggle,
                ),
                _ThumbGrid(
                  items: result.largeFiles,
                  selected: selected,
                  onToggle: onToggle,
                  emptyMessage: '冇大過 20MB 嘅檔案，好好呀 👍',
                ),
              ],
            ),
          ),
        ],
      ),
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

/// 重複分組：每組用一行縮圖顯示，留 1 張其餘預設揀選。
class _DuplicateTab extends StatelessWidget {
  final List<DuplicateGroup> groups;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  const _DuplicateTab({
    required this.groups,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const Center(
        child: Text(
          '搵唔到重複相片 👍',
          style: TextStyle(color: AppColors.caption, fontSize: 14),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _DuplicateGroupCard(
        group: groups[i],
        selected: selected,
        onToggle: onToggle,
      ),
    );
  }
}

class _DuplicateGroupCard extends StatelessWidget {
  final DuplicateGroup group;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  const _DuplicateGroupCard({
    required this.group,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final int dupeCount = group.count - 1;
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
                  '${group.count} 張重複 · ${formatBytes(group.totalMB)}',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
              Text(
                '删 $dupeCount 張 · 可騰 ${formatBytes(dupeCount * group.items.first.sizeBytes)}',
                style: const TextStyle(color: AppColors.success, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: cell,
            child: Row(
              children: [
                for (int k = 0; k < group.items.length; k++) ...[
                  if (k > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _SelectableThumb(
                      item: group.items[k],
                      isKept: k == 0,
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