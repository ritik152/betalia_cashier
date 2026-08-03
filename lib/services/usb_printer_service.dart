import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_usb_printer/flutter_usb_printer.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UsbPrinterService extends ChangeNotifier {
  static final UsbPrinterService _instance = UsbPrinterService._internal();
  factory UsbPrinterService() => _instance;
  UsbPrinterService._internal();

  final FlutterUsbPrinter _usbPrinter = FlutterUsbPrinter();

  bool _isConnected = false;
  bool _isConnecting = false;
  Map<String, dynamic>? _connectedDevice;

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectedDeviceName =>
      _connectedDevice?['productName'] ?? _connectedDevice?['deviceName'];

  // ---------------------------------------------------------------------------
  // SharedPreferences keys for persisted USB printer identity
  // ---------------------------------------------------------------------------
  static const String _prefVendorIdKey = 'usb_printer_vendor_id';
  static const String _prefProductIdKey = 'usb_printer_product_id';

  // ---------------------------------------------------------------------------
  // Device discovery
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getUsbDevices() async {
    try {
      final List<Map<String, dynamic>> results =
          await FlutterUsbPrinter.getUSBDeviceList();
      debugPrint('UsbPrinterService: USB devices found: ${results.length}');
      return results;
    } catch (e) {
      debugPrint('UsbPrinterService: Error getting USB devices: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Automatic connection (ensureConnected)
  // ---------------------------------------------------------------------------

  /// Ensures a USB printer is connected, reconnecting automatically when
  /// possible.  Returns `true` when the service is already connected or
  /// reconnects successfully.
  ///
  /// * Returns `true` immediately if [isConnected] is already `true`.
  /// * Tries the persisted vendor / product IDs first.
  /// * Falls back to a single attached device if exactly one USB device exists.
  /// * Returns `false` when no suitable printer could be found or connected.
  /// * Uses an `_isConnecting` guard to prevent concurrent attempts.
  Future<bool> ensureConnected() async {
    // Already connected – nothing to do.
    if (_isConnected) {
      debugPrint('UsbPrinterService: already connected, skipping ensureConnected');
      return true;
    }

    // Prevent overlapping connection attempts.
    if (_isConnecting) {
      debugPrint('UsbPrinterService: connection attempt already in progress');
      return false;
    }

    _isConnecting = true;

    try {
      final List<Map<String, dynamic>> devices = await getUsbDevices();

      if (devices.isEmpty) {
        debugPrint('UsbPrinterService: no USB devices attached');
        return false;
      }

      // 1) Try the previously-saved printer.
      final prefs = await SharedPreferences.getInstance();
      final String? savedVendorStr = prefs.getString(_prefVendorIdKey);
      final String? savedProductStr = prefs.getString(_prefProductIdKey);

      if (savedVendorStr != null && savedProductStr != null) {
        final int? savedVendorId = int.tryParse(savedVendorStr);
        final int? savedProductId = int.tryParse(savedProductStr);

        if (savedVendorId != null && savedProductId != null) {
          debugPrint(
            'UsbPrinterService: looking for saved printer '
            'VID=$savedVendorId PID=$savedProductId',
          );

          // Find the matching device in the current list.
          final Map<String, dynamic>? matchedDevice = devices.cast<Map<String, dynamic>?>().firstWhere(
            (d) {
              if (d == null) return false;
              final int? vid = int.tryParse(d['vendorId']?.toString() ?? '');
              final int? pid = int.tryParse(d['productId']?.toString() ?? '');
              return vid == savedVendorId && pid == savedProductId;
            },
            orElse: () => null,
          );

          if (matchedDevice != null) {
            debugPrint('UsbPrinterService: found saved printer, connecting...');
            return await connectToDevice(matchedDevice);
          }

          debugPrint(
            'UsbPrinterService: saved printer not found among '
            'attached devices',
          );
        }
      }

      // 2) If no saved printer matched, check for a single device.
      if (devices.length == 1) {
        debugPrint(
          'UsbPrinterService: exactly one USB device attached, '
          'auto-connecting',
        );
        return await connectToDevice(devices.first);
      }

      // 3) Multiple devices and no saved match – log details and return false.
      debugPrint(
        'UsbPrinterService: multiple USB devices attached but none '
        'match the saved printer.  Detected devices:',
      );
      for (final d in devices) {
        debugPrint(
          '  - ${d['productName'] ?? d['deviceName'] ?? 'Unknown'} '
          '(VID: ${d['vendorId']}, PID: ${d['productId']})',
        );
      }

      return false;
    } catch (e) {
      debugPrint('UsbPrinterService: ensureConnected error: $e');
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Manual connection
  // ---------------------------------------------------------------------------

  /// Connects to a specific USB device identified by [device] (must contain
  /// `vendorId` and `productId`).
  ///
  /// * Parses IDs safely with `int.tryParse`.
  /// * Persists the IDs on success.
  /// * Resets state on failure.
  /// * Always clears `_isConnecting` in `finally`.
  /// * Fires [notifyListeners] on every state change.
  Future<bool> connectToDevice(Map<String, dynamic> device) async {
    _isConnecting = true;

    try {
      final int? vendorId = int.tryParse(device['vendorId']?.toString() ?? '');
      final int? productId = int.tryParse(device['productId']?.toString() ?? '');

      if (vendorId == null || productId == null) {
        debugPrint(
          'UsbPrinterService: invalid device IDs – '
          'vendorId=${device['vendorId']}, productId=${device['productId']}',
        );
        _isConnected = false;
        _connectedDevice = null;
        notifyListeners();
        return false;
      }

      debugPrint(
        'UsbPrinterService: connecting to VID=$vendorId PID=$productId...',
      );

      final bool? success = await _usbPrinter.connect(vendorId, productId);

      if (success == true) {
        _isConnected = true;
        _connectedDevice = device;

        // Persist the printer identity for future auto-connect.
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefVendorIdKey, vendorId.toString());
          await prefs.setString(_prefProductIdKey, productId.toString());
          debugPrint(
            'UsbPrinterService: saved printer identity '
            'VID=$vendorId PID=$productId',
          );
        } catch (e) {
          debugPrint('UsbPrinterService: failed to save printer identity: $e');
        }

        debugPrint(
          'UsbPrinterService: connected to '
          '${device['productName'] ?? device['deviceName'] ?? 'Unknown USB Printer'}',
        );
        notifyListeners();
        return true;
      }

      // Connection returned null or false.
      debugPrint('UsbPrinterService: connection returned $success');
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } on PlatformException catch (e) {
      debugPrint(
        'UsbPrinterService: platform error connecting to USB printer: '
        '${e.message}',
      );
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('UsbPrinterService: error connecting to USB printer: $e');
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Disconnect
  // ---------------------------------------------------------------------------

  /// Disconnects from the USB printer and resets all connection state.
  /// Always calls [notifyListeners] even if the native close throws.
  Future<void> disconnect() async {
    try {
      await _usbPrinter.close();
      debugPrint('UsbPrinterService: USB printer closed');
    } catch (e) {
      debugPrint('UsbPrinterService: error closing USB printer: $e');
    } finally {
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Print receipt
  // ---------------------------------------------------------------------------

  /// Generates and sends the receipt to the connected USB printer.
  ///
  /// When [openDrawer] is `true` the cash-drawer kick command is appended to
  /// the same byte payload after the paper-feed and before the cut.
  ///
  /// Returns `true` when the bytes were written successfully (the application
  /// only knows the command was sent – it cannot confirm that the drawer
  /// physically opened).
  ///
  /// Resets the USB connection state and returns `false` when the write call
  /// fails or returns a non-success value.
  Future<bool> printBill(
    Map<String, dynamic> data, {
    bool openDrawer = false,
  }) async {
    if (!_isConnected) {
      debugPrint('UsbPrinterService: no USB printer connected');
      return false;
    }

    final Map<String, dynamic> order =
        data['order'] as Map<String, dynamic>? ?? {};
    final Map<String, dynamic> vendor =
        data['vendor'] as Map<String, dynamic>? ?? {};

    if (order.isEmpty && vendor.isEmpty) {
      debugPrint('UsbPrinterService: receipt dataset payload is empty');
      return false;
    }

    try {
      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.mm80, profile);
      List<int> bytes = [];

      // =====================================================================
      // 1. VENDOR HEADER BLOCK
      // =====================================================================
      final String vendorName = vendor['name'] as String? ?? 'Restaurant';
      bytes += generator.text(
        vendorName,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      );

      if (vendor['address'] != null) {
        bytes += generator.text(
          vendor['address'] as String,
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['city'] != null) {
        final String zip = vendor['zipCode'] as String? ?? '';
        bytes += generator.text(
          '${vendor['city']} $zip'.trim(),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['phone'] != null) {
        bytes += generator.text(
          'Tel: ${vendor['phone']}',
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['organizationId'] != null) {
        bytes += generator.text(
          'Org ID: ${vendor['organizationId']}',
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      bytes += generator.hr();

      // =====================================================================
      // 2. RECEIPT META TITLE BLOCK
      // =====================================================================
      final bool isCopy = order['isCopy'] == true;
      final String receiptLabel =
          isCopy ? 'KOPIKVITTERING' : 'SALGSKVITTERING';
      bytes += generator.text(
        receiptLabel,
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        'Receipt - ${order['orderNumber'] ?? ''}',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );

      bytes += generator.hr();

      // =====================================================================
      // 3. ORDER DATA BLOCK (Key-Value Rows)
      // =====================================================================
      bytes += generator.row([
        PosColumn(text: 'Order Type:', width: 6),
        PosColumn(
          text: '${order['orderType'] ?? ''}'.toUpperCase(),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Payment:', width: 6),
        PosColumn(
          text: '${order['paymentMethod'] ?? ''}'.toUpperCase(),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Cashier :', width: 6),
        PosColumn(
          text: '${order['cashierName'] ?? '-'}',
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Terminal:', width: 6),
        PosColumn(
          text: '${order['deviceId'] ?? ''}',
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      final List itemsList = order['items'] as List? ?? [];
      int totalItemCount = itemsList.fold<int>(0, (sum, item) {
        return sum + ((item['quantity'] as num?)?.toInt() ?? 0);
      });

      bytes += generator.row([
        PosColumn(text: 'Total Items', width: 6),
        PosColumn(
          text: '$totalItemCount',
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      bytes += generator.hr();

      // =====================================================================
      // 4. ITEMS GRID HEADERS
      // =====================================================================
      bytes += generator.row([
        PosColumn(text: 'Item', width: 7, styles: const PosStyles(bold: true)),
        PosColumn(
          text: 'Qty',
          width: 2,
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
        PosColumn(
          text: 'Price',
          width: 3,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      // =====================================================================
      // 5. PRINTING DYNAMIC ITEMS & SUBITEMS
      // =====================================================================
      for (var itemDynamic in itemsList) {
        final Map<String, dynamic> item = itemDynamic as Map<String, dynamic>;

        double price = (item['price'] as num? ?? 0.0).toDouble();
        final int qty = (item['quantity'] as num? ?? 1).toInt();
        final double computedTotalPrice = price * qty;

        String itemName = '';
        if (item['menuItemId'] != null && item['menuItemId'] is Map) {
          final Map<dynamic, dynamic> menuItemField =
              item['menuItemId'] as Map;
          itemName = menuItemField['name']?.toString() ?? '';
        }

        bytes += generator.row([
          PosColumn(text: itemName, width: 7),
          PosColumn(
            text: '$qty',
            width: 2,
            styles: const PosStyles(align: PosAlign.center),
          ),
          PosColumn(
            text: computedTotalPrice.toStringAsFixed(2),
            width: 3,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);

        final List? selectedOptions = item['selectedOptions'] as List?;
        final List? subItems = item['subItems'] as List?;

        if (selectedOptions != null &&
            selectedOptions.isNotEmpty &&
            (subItems == null || subItems.isEmpty)) {
          for (var og in selectedOptions) {
            final List choicesList = og['choices'] as List? ?? [];
            final String choicesStr =
                choicesList.map((c) => c['name']?.toString() ?? '').join(', ');
            bytes += generator.text(
              '  ${og['groupName']}: $choicesStr',
              styles: const PosStyles(align: PosAlign.left),
            );
          }
        }

        if (subItems != null && subItems.isNotEmpty) {
          for (var subDynamic in subItems) {
            final Map<String, dynamic> sub = subDynamic as Map<String, dynamic>;
            final int subQty = (sub['quantity'] as num? ?? 1).toInt();
            final String subPrefix = subQty > 1 ? '${subQty}x ' : '';

            bytes += generator.text(
              '  $subPrefix${sub['name'] ?? ''}',
              styles: const PosStyles(align: PosAlign.left),
            );

            final List? subOpts = sub['selectedOptions'] as List?;
            if (subOpts != null && subOpts.isNotEmpty) {
              for (var subOg in subOpts) {
                final List choicesList = subOg['choices'] as List? ?? [];
                final String choicesStr = choicesList
                    .map((c) => c['name']?.toString() ?? '')
                    .join(', ');
                bytes += generator.text(
                  '    ${subOg['groupName']}: $choicesStr',
                  styles: const PosStyles(align: PosAlign.left),
                );
              }
            }
          }
        }
      }

      bytes += generator.hr();

      // =====================================================================
      // 6. GRAND TOTAL ROW
      // =====================================================================
      final double totalPrice =
          (order['totalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row([
        PosColumn(
          text: 'TOTAL',
          width: 5,
          styles: const PosStyles(
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size1,
          ),
        ),
        PosColumn(
          text: 'kr ${totalPrice.toStringAsFixed(2)}',
          width: 7,
          styles: const PosStyles(
            align: PosAlign.right,
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size1,
          ),
        ),
      ]);

      bytes += generator.hr();

      // =====================================================================
      // 7. TAXES SUMMARY
      // =====================================================================
      final double subtotalPrice =
          (order['subtotalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row([
        PosColumn(text: 'Subtotal', width: 6),
        PosColumn(
          text: 'kr ${subtotalPrice.toStringAsFixed(2)}',
          width: 6,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      final double vatPrice = (order['vatPrice'] as num? ?? 0.0).toDouble();
      if (vatPrice > 0) {
        final Map<String, double> vatRates = {
          'takeaway': 0.15,
          'dine': 0.25,
          'delivery': 0.15,
        };
        final double ratePercent =
            (vatRates[order['orderType']] ?? 0.15) * 100;

        bytes += generator.row([
          PosColumn(
            text: 'VAT (${ratePercent.toStringAsFixed(0)}%)',
            width: 6,
          ),
          PosColumn(
            text: 'kr ${vatPrice.toStringAsFixed(2)}',
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      bytes += generator.hr();

      // =====================================================================
      // 8. FOOTER / BRANDING BLOCK
      // =====================================================================
      final Map<String, dynamic> vendorOthers =
          vendor['others'] as Map<String, dynamic>? ?? {};
      final String receiptMessage =
          vendorOthers['receiptMessage'] as String? ?? 'Takk for deres besøk!';

      bytes += generator.text(
        receiptMessage,
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        vendorName,
        styles: const PosStyles(align: PosAlign.center),
      );

      final String createdAtStr =
          order['createdAt']?.toString() ?? DateTime.now().toIso8601String();
      try {
        final DateTime dt = DateTime.parse(createdAtStr);
        const List<String> months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        final String formattedDate =
            '${dt.day.toString().padLeft(2, '0')} '
            '${months[dt.month - 1]} ${dt.year} '
            'at ${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}';
        bytes += generator.text(
          formattedDate,
          styles: const PosStyles(align: PosAlign.center),
        );
      } catch (_) {
        bytes += generator.text(
          createdAtStr,
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      if (vendor['website'] != null &&
          (vendor['website'] as String).trim().isNotEmpty) {
        bytes += generator.text(
          vendor['website'] as String,
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      // =====================================================================
      // 9. PAPER FEED, OPTIONAL CASH DRAWER, CUT
      // =====================================================================
      bytes += generator.feed(3);

      // Cash-drawer command (change pin5 to pin2 if your printer requires it).
      // See PosDrawer.pin2 / PosDrawer.pin5 enum values.
      if (openDrawer) {
        bytes += generator.drawer(pin: PosDrawer.pin2);
        debugPrint('UsbPrinterService: cash drawer command appended');
      }

      bytes += generator.cut();

      // =====================================================================
      // 10. SINGLE USB WRITE – CHECK THE RETURN VALUE
      // =====================================================================
      debugPrint(
        'UsbPrinterService: sending ${bytes.length} bytes to USB printer '
        '(drawer: $openDrawer)',
      );

      bool? writeResult;
      try {
        writeResult = await _usbPrinter.write(Uint8List.fromList(bytes));
      } catch (e) {
        debugPrint('UsbPrinterService: USB write threw exception: $e');
        _resetConnectionState();
        return false;
      }

      if (writeResult == false) {
        debugPrint('UsbPrinterService: USB write returned false');
        _resetConnectionState();
        return false;
      }

      debugPrint('UsbPrinterService: receipt sent successfully');
      return true;
    } on PlatformException catch (e) {
      debugPrint(
        'UsbPrinterService: platform error printing: ${e.message}',
      );
      return false;
    } catch (e) {
      debugPrint('UsbPrinterService: error printing USB bill: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Resets connection state after a write failure so the next print attempt
  /// will try to reconnect.
  void _resetConnectionState() {
    _isConnected = false;
    _connectedDevice = null;
    notifyListeners();
    debugPrint('UsbPrinterService: connection state reset after write failure');
  }
}