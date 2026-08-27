import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/trash_manager.dart';
import '../theme.dart';

/// 垃圾桶入口頁：列出已備份嘅相片／影片，可以「還原」或「永久刪除」。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<TrashEntry> _entries = <TrashEntry>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<TrashEntry> list = await TrashManager.list();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  Future<void> _restore(TrashEntry e) async {
    final bool ok = await TrashManager.restore(e);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已還原「${e.title}」' : '還原失敗，請再試。'),
        backgroundColor: ok ? AppColors.success : AppColors.danger,
      ),
    );
    if (ok) _reload();
  }

  Future<void> _deletePermanently(TrashEntry e) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('永久刪除'),
        content: Text(
          '「${e.title}」會從垃圾桶永久移除，唔可以再還原。確定？',
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
    await TrashManager.removePermanently(e);
    if (mounted) _reload();
  }

  Future<void> _emptyTrash() async {
    if (_entries.isEmpty) return;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('清空垃圾桶'),
        content: Text(
          '會永久刪除垃圾桶內全部 ${_entries.length} 項，唔可以再還原。確定？',
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
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await TrashManager.emptyTrash();
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final int bytes = _entries.fold(0, (s, e) => s + e.sizeBytes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('垃圾桶'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _entries.isEmpty
                ? const Center(
                    child: Text(
                      '垃圾桶係空嘅，刪除前相片／影片會先備份喺呢度。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.caption, fontSize: 14),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                        child: Row(
                          children: [
                            _infoChip(
                              icon: Icons.delete_outline,
                              text: '${_entries.length} 項',
                            ),
                            const SizedBox(width: 10),
                            _infoChip(
                              icon: Icons.data_usage,
                              text: _fmt(bytes),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _emptyTrash,
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.danger,
                              ),
                              icon: const Icon(Icons.delete_sweep_outlined,
                                  size: 18),
                              label: const Text('清空'),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) =>
                              _TrashCard(
                                entry: _entries[i],
                                onRestore: () => _restore(_entries[i]),
                                onDelete: () => _deletePermanently(_entries[i]),
                              ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _infoChip({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.caption, size: 14),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
                color: AppColors.caption, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  static String _fmt(int bytes) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _TrashCard extends StatelessWidget {
  final TrashEntry entry;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  const _TrashCard({
    required this.entry,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          // 縮圖。
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: entry.type == 'video' || kIsWeb
                ? Icon(
                    entry.type == 'video'
                        ? Icons.movie_outlined
                        : Icons.image_outlined,
                    color: AppColors.caption,
                    size: 28,
                  )
                : Image.file(
                    File(entry.filePath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: AppColors.caption,
                      size: 28,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_fmt(entry.sizeBytes)} · ${entry.type == 'video' ? '影片' : '相片'}',
                  style:
                      const TextStyle(color: AppColors.caption, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onDelete,
            tooltip: '永久刪除',
            icon: const Icon(Icons.delete_outline, color: AppColors.caption),
          ),
          FilledButton.icon(
            onPressed: onRestore,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            icon: const Icon(Icons.restore, size: 17),
            label: const Text('還原'),
          ),
        ],
      ),
    );
  }

  static String _fmt(int bytes) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
