import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import '../models/analysis_result.dart';

/// 定期掃描提醒。
///
/// 用 flutter_local_notifications：
/// - 每日排一個週期通知（「有新相片可清理」）。
/// - 掃描之後比較本地儲存嘅結果：發現「新重複」（比上次多）就即刻彈通知，
///   而且最多每日 1 次（記錄 lastNotifiedDate）。
///
/// 掃描結果／通知記錄存喺 app 私人目錄 scan_history.json。
/// Web 平台冇通知／檔案系統支援，所有操作都會安全跳過。
class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  static const int _dailyId = 9001;
  static const int _newDupeId = 9002;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;

  /// 初始化 + 攞通知權限 + 排每日提醒。喺 App 啟動時呼叫。
  Future<void> init() async {
    if (kIsWeb) return;
    try {
      const AndroidInitializationSettings android =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings ios = DarwinInitializationSettings();
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
      );
      // Android 13+ 需要 POST_NOTIFICATIONS 權限。
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _inited = true;
      await _scheduleDailyReminder();
    } catch (e) {
      debugPrint('ReminderService.init error: $e');
    }
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          'photo_cleaner_reminder',
          '相片清理提醒',
          channelDescription: '每日提醒你清理新相片',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      );

  /// 每日（週期）提醒「有新相片可清理」。
  Future<void> _scheduleDailyReminder() async {
    try {
      await _plugin.periodicallyShow(
        _dailyId,
        '相片清理',
        '最近有新相片可以清理，打開 App 睇吓啦 😀',
        RepeatInterval.daily,
        _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      debugPrint('ReminderService.scheduleDaily error: $e');
    }
  }

  /// 掃描完成之後呼叫：將結果存 local，發現新重複先提醒（每日最多 1 次）。
  Future<void> updateAfterScan(ScanResult result) async {
    if (kIsWeb || !_inited) return;
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final File f =
          File('${docs.path}${Platform.pathSeparator}scan_history.json');
      Map<String, dynamic> hist = <String, dynamic>{};
      if (await f.exists()) {
        try {
          final dynamic decoded = jsonDecode(await f.readAsString());
          if (decoded is Map<String, dynamic>) hist = decoded;
        } catch (_) {}
      }

      final int prevDupeGroups = (hist['duplicateGroups'] as num?)?.toInt() ?? 0;
      final String? lastNotified = hist['lastNotifiedDate'] as String?;
      final String today = _today();
      final int curDupeGroups = result.duplicateGroups.length;
      final double freedMB = result.recoverableDuplicateBytes / (1024 * 1024);

      // 發現新重複（組數多咗）＋ 今日未通知過 → 彈通知。
      if (curDupeGroups > prevDupeGroups &&
          lastNotified != today &&
          curDupeGroups > 0) {
        await _plugin.show(
          _newDupeId,
          '有新相片可清理',
          '發現 $curDupeGroups 組新重複相片，約可騰出 ${freedMB.toStringAsFixed(1)} MB 空間。',
          _details,
        );
        hist['lastNotifiedDate'] = today;
      }

      hist['duplicateGroups'] = curDupeGroups;
      hist['lastScanDate'] = DateTime.now().toIso8601String();
      await f.writeAsString(jsonEncode(hist));
    } catch (e) {
      debugPrint('ReminderService.updateAfterScan error: $e');
    }
  }

  static String _today() {
    final DateTime n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }
}
