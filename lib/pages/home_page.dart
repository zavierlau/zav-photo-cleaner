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
      final List<AssetItem> items =
          await PhotoScanner.scanAllAssets();
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
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('確認刪除'),
        content: Text(
          '將刪除 ${_selected.length} 項檔案，可騰出 '
          '${formatBytes(totalBytes)} 嘅空間。\n\n此操作會將相片/影片放入（Android）垃圾桶／永久移除，請確認。',
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
      // 刪完之後自動重新掃描，刷新列表。
      if (deletedCount > 0) {
        _rescanAfterDelete();
      }
    });
  }

  Future<void> _rescanAfterDelete() async {
    try {
      final List<AssetItem> items =
          await PhotoScanner.scanAllAssets();
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
    final int duplicateCount = _result!.duplicateGroups
        .fold(0, (sum, g) => sum + (g.count - 1));
    final int largeCount = _result!.largeFiles.length;

    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildSummaryHeader(duplicateCount, largeCount)),
          _buildResultTabs(),
        ],
      ),
    );
  }

  Widget _buildSummaryHeader(int duplicateCount, int largeCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Stat(label: '資產', value: '${_result!.all.length}'),
              const SizedBox(width: 20),
              _Stat(label: '重複多餘', value: '$duplicateCount'),
              const SizedBox(width: 20),
              _Stat(label: '大檔案', value: '$largeCount'),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            '掃描完成，以下係分析結果。',
            style: TextStyle(color: AppColors.caption, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTabs() {
    return Expanded(
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(24, 8, 24, 8),
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
                Tab(text: '重複相片 ${_result!.duplicateGroups.length}'),
                Tab(text: '大檔案 ${_result!.largeFiles.length}'),
                Tab(text: '可騰空間'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _DuplicateTab(groups: _result!.duplicateGroups, selected: _selected, onToggle: _toggle),
                _LargeTab(items: _result!.largeFiles, selected: _selected, onToggle: _toggle),
                _SpaceTab(selected: _selected, result: _result!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(label, style: const TextStyle(color: AppColors.caption, fontSize: 11)),
      ],
    );
  }
}

/// 出錯相片縮圖（細圖）。
class _AssetThumb extends StatelessWidget {
  final AssetEntity entity;
  final double size;
  const _AssetThumb({required this.entity, this.size = 44});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: FutureBuilder<Uint8List?>(
          future: entity.thumbnailDataWithSize(ThumbnailSize(88, 88)),
          builder: (context, snap) {
            final data = snap.data;
            if (data == null) {
              return Container(
                color: AppColors.card,
                child: Icon(
                  entity.type == AssetType.video
                      ? Icons.movie_outlined
                      : Icons.image_outlined,
                  color: AppColors.caption,
                  size: size * 0.5,
                ),
              );
            }
            return Image.memory(data, fit: BoxFit.cover);
          },
        ),
      ),
    );
  }
}

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
      return const _Empty(message: '搵唔到重複相片 👍');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _GroupCard(
        group: groups[i],
        selected: selected,
        onToggle: onToggle,
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final DuplicateGroup group;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  const _GroupCard({
    required this.group,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final int dupeCount = group.count - 1;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${group.count} 張重複 · ${formatBytes(group.items.fold(0, (s, a) => s + a.sizeBytes))}',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              Text(
                '保留 1 張',
                style: const TextStyle(color: AppColors.caption, fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (dupeCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '可刪 $dupeCount 張，騰出 ${formatBytes(dupeCount * group.items.first.sizeBytes)}',
                style: const TextStyle(color: AppColors.caption, fontSize: 12),
              ),
            ),
          for (int k = 0; k < group.items.length; k++)
            _AssetRow(
              item: group.items[k],
              isSelected: selected.containsKey(group.items[k].id),
              isKept: k == 0,
              onToggle: onToggle,
            ),
        ],
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  final AssetItem item;
  final bool isSelected;
  final bool isKept;
  final void Function(AssetItem, bool) onToggle;
  const _AssetRow({
    required this.item,
    required this.isSelected,
    required this.isKept,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onToggle(item, !isSelected),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _AssetThumb(entity: item.entity),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.isVideo ? '影片' : '相片',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatBytes(item.sizeBytes)} · ${item.entity.width}×${item.entity.height}',
                    style: const TextStyle(color: AppColors.caption, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            if (isKept)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text(
                  '保留',
                  style: TextStyle(color: AppColors.caption, fontSize: 11),
                ),
              )
            else
              Checkbox(
                value: isSelected,
                onChanged: (v) => onToggle(item, v ?? false),
              ),
          ],
        ),
      ),
    );
  }
}

class _LargeTab extends StatelessWidget {
  final List<AssetItem> items;
  final Map<String, AssetItem> selected;
  final void Function(AssetItem, bool) onToggle;
  const _LargeTab({required this.items, required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _Empty(message: '冇大過 20MB 嘅檔案，好好呀 👍');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, i) => _LargeRow(
        item: items[i],
        isSelected: selected.containsKey(items[i].id),
        onToggle: onToggle,
      ),
    );
  }
}

class _LargeRow extends StatelessWidget {
  final AssetItem item;
  final bool isSelected;
  final void Function(AssetItem, bool) onToggle;
  const _LargeRow({required this.item, required this.isSelected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onToggle(item, !isSelected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _AssetThumb(entity: item.entity),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.isVideo ? '影片' : '相片',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${item.entity.width}×${item.entity.height}',
                    style: const TextStyle(color: AppColors.caption, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            Text(
              formatBytes(item.sizeBytes),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Checkbox(
              value: isSelected,
              onChanged: (v) => onToggle(item, v ?? false),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpaceTab extends StatelessWidget {
  final Map<String, AssetItem> selected;
  final ScanResult result;
  const _SpaceTab({required this.selected, required this.result});

  @override
  Widget build(BuildContext context) {
    final int bytes = selected.values.fold(0, (sum, a) => sum + a.sizeBytes);
    final int auto = result.recoverableDuplicateBytes;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatBytes(bytes),
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 44,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '目前揀選咗嘅檔案總共可騰出嘅空間',
            style: TextStyle(color: AppColors.caption, fontSize: 13),
          ),
          const SizedBox(height: 32),
          _SpaceRow(
            icon: Icons.content_copy_outlined,
            label: '重複多餘（已預揀）',
            value: formatBytes(auto),
          ),
          const SizedBox(height: 18),
          _SpaceRow(
            icon: Icons.memory_outlined,
            label: '已揀要刪除',
            value: formatBytes(bytes),
            emphasize: true,
          ),
        ],
      ),
    );
  }
}

class _SpaceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool emphasize;
  const _SpaceRow({
    required this.icon,
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.caption, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: emphasize ? AppColors.accent : AppColors.text,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: emphasize ? AppColors.accent : AppColors.text,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String message;
  const _Empty({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.caption, fontSize: 14),
        ),
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
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E5EA))),
        ),
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              disabledBackgroundColor: const Color(0xFFE0E0E5),
              disabledForegroundColor: AppColors.caption,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            child: onPressed == null
                ? const Text('刪除')
                : Text('刪除  $count 項 · $freedMB'),
          ),
        ),
      ),
    );
  }
}

/// 格式化 bytes 做易讀 MB。
String formatBytes(num bytes) {
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}