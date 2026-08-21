import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const String handle = 'bakeri';
  static const String apiBase = 'http://192.168.1.3:3001';
  static const Duration pollInterval = Duration(seconds: 15);

  // The service notification is intentionally quiet. Order alerts use a new,
  // versioned high-importance channel because Android channel importance is
  // immutable after the channel has first been created on a device.
  static const String _serviceChannelId = 'betalia_order_monitor_service_v2';
  static const String _orderAlertChannelId = 'betalia_order_alerts_v2';
  static const String _deliveredNotificationIdsKey =
      'cashier_delivered_notification_ids_v2';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _isPolling = false;
  bool _notificationsReady = false;
  bool _isAppInForeground = false;
  int? _lastUnreadCount;
  ServiceInstance? _serviceInstance;

  Future<void> initialize({bool requestPermission = true}) async {
    if (!_notificationsReady) {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      );
      await _localNotifications.initialize(settings: settings);

      const serviceChannel = AndroidNotificationChannel(
        _serviceChannelId,
        'Order notification service',
        description: 'Keeps Betalia order monitoring active',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      );
      const alertChannel = AndroidNotificationChannel(
        _orderAlertChannelId,
        'New Orders',
        description: 'Notifications for new online, QR-code, and kiosk orders',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      );

      final android = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(serviceChannel);
      await android?.createNotificationChannel(alertChannel);
      _notificationsReady = true;
    }

    if (requestPermission) {
      final android = _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
    }
  }

  Future<void> initializeBackgroundService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onServiceStart,
        autoStart: true,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: _serviceChannelId,
        initialNotificationTitle: 'New order notifications',
        initialNotificationContent: 'Starting order monitoring…',
        foregroundServiceNotificationId: 9001,
        foregroundServiceTypes: const [AndroidForegroundType.specialUse],
      ),
      // iOS cannot provide Android-style persistent background polling. The
      // app's foreground web UI remains responsible there.
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onServiceStart,
        onBackground: onIosBackground,
      ),
    );

    if (!await service.isRunning()) {
      await service.startService();
    }

    // The app is necessarily visible while main() configures the service. This
    // event also reaches a service that was already running after boot.
    setAppInForeground(true);
  }

  void setAppInForeground(bool isForeground) {
    FlutterBackgroundService().invoke('appLifecycle', {
      'isForeground': isForeground,
    });
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void onServiceStart(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    final notificationService = NotificationService.instance;
    notificationService._serviceInstance = service;

    service.on('stopService').listen((event) {
      service.stopSelf();
    });
    service.on('appLifecycle').listen((event) {
      notificationService._isAppInForeground = event?['isForeground'] == true;
    });

    if (service is AndroidServiceInstance) {
      try {
        await service.setAsForegroundService();
        await service.setForegroundNotificationInfo(
          title: 'New order notifications',
          content: 'Starting order monitoring…',
        );
      } catch (error) {
        debugPrint('NotificationService foreground setup error: $error');
      }
    }

    // Notification plugin registration must not be able to stop the HTTP poll.
    try {
      await notificationService.initialize(requestPermission: false);
    } catch (error, stack) {
      notificationService._notificationsReady = false;
      debugPrint('NotificationService initialization error: $error\n$stack');
      await notificationService._updateServiceStatus(
        'Alert setup failed; polling will retry',
      );
    }

    // Allow the foreground lifecycle event from main() to arrive before the
    // first canonical-list delivery check.
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await notificationService.pollNow();
    Timer.periodic(pollInterval, (_) {
      unawaited(notificationService.pollNow());
    });
  }

  Future<void> pollNow() async {
    if (_isPolling) return;
    _isPolling = true;

    try {
      final result = await _fetchNotifications();

      if (!_notificationsReady) {
        try {
          await initialize(requestPermission: false);
        } catch (error) {
          debugPrint('NotificationService alert retry error: $error');
        }
      }

      try {
        await _notifyUndelivered(result.notifications);
      } catch (error, stack) {
        debugPrint('NotificationService delivery error: $error\n$stack');
      }

      await _updateBadge(result.unreadCount);
      await _updateServiceStatus(
        'Last check ${_formatTime(DateTime.now())} • '
        '${result.unreadCount} unread',
      );
    } catch (error, stack) {
      debugPrint('NotificationService poll error: $error\n$stack');
      await _updateServiceStatus(
        'Last check failed ${_formatTime(DateTime.now())}: $error',
      );
    } finally {
      _isPolling = false;
    }
  }

  Future<({List<Map<String, dynamic>> notifications, int unreadCount})>
  _fetchNotifications() async {
    final uri = Uri.parse('$apiBase/cashier-notifactions/$handle');
    final response = await http
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'Cache-Control': 'no-cache, no-store',
            'Pragma': 'no-cache',
            'X-Notification-Client': 'android-service',
          },
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw Exception('Invalid notification response');
    }

    // The canonical list prevents the embedded web poll and this background
    // poll from racing over which client receives a newly-created row.
    final rawNotifications =
        (decoded['notifications'] ?? decoded['newNotifications'])
            as List<dynamic>? ??
        [];
    return (
      notifications: rawNotifications
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(),
      unreadCount: (decoded['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> _notifyUndelivered(
    List<Map<String, dynamic>> notifications,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();

    final currentIds = notifications
        .map((notification) => notification['_id']?.toString())
        .whereType<String>()
        .toSet();
    final deliveredIds =
        (preferences.getStringList(_deliveredNotificationIdsKey) ?? <String>[])
            .toSet()
          ..retainWhere(currentIds.contains);

    for (final notification in notifications.reversed) {
      final id = notification['_id']?.toString();
      if (id == null || deliveredIds.contains(id)) continue;

      // The embedded web UI owns foreground toast/panel delivery. Marking the
      // canonical ID delivered here prevents a duplicate OS alert on pause.
      if (_isAppInForeground) {
        deliveredIds.add(id);
        continue;
      }

      if (!_notificationsReady) continue;
      await _notify(notification);
      deliveredIds.add(id);
    }

    await preferences.setStringList(
      _deliveredNotificationIdsKey,
      deliveredIds.toList(),
    );
  }

  Future<void> _updateBadge(int unreadCount) async {
    if (_lastUnreadCount == unreadCount) return;
    _lastUnreadCount = unreadCount;

    try {
      if (unreadCount > 0) {
        await FlutterAppBadger.updateBadgeCount(unreadCount);
      } else {
        await FlutterAppBadger.removeBadge();
      }
    } catch (error) {
      debugPrint('NotificationService badge error: $error');
    }
  }

  Future<void> _notify(Map<String, dynamic> notification) async {
    final channel = notification['channel'] as String? ?? '';
    final orderNumber = notification['orderNumber']?.toString() ?? '';
    final tableNumber = notification['tableNumber']?.toString();
    final paymentMethod = notification['paymentMethod']
        ?.toString()
        .toLowerCase();

    final body = switch (channel) {
      'QR-code' =>
        'New order - $orderNumber From Table - ${tableNumber ?? '?'}',
      'kiosk' =>
        'New order - $orderNumber from Kiosk '
            '${paymentMethod == 'cash' ? 'Cash' : 'Card'}',
      _ => 'New order - $orderNumber from Online',
    };

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _orderAlertChannelId,
        'New Orders',
        channelDescription:
            'Notifications for new online, QR-code, and kiosk orders',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final notificationId =
        (notification['_id']?.toString() ?? orderNumber).hashCode & 0x7fffffff;
    await _localNotifications.show(
      id: notificationId,
      title: 'New Order',
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> _updateServiceStatus(String content) async {
    final service = _serviceInstance;
    if (service is! AndroidServiceInstance) return;

    try {
      await service.setForegroundNotificationInfo(
        title: 'New order notifications',
        content: content.length > 120 ? content.substring(0, 120) : content,
      );
    } catch (error) {
      debugPrint('NotificationService status error: $error');
    }
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
