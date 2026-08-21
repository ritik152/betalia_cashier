import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_usb_printer/flutter_usb_printer.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/printer_text_utils.dart';

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

  // SharedPreferences keys for persisted USB printer identity
  static const String _prefVendorIdKey = 'usb_printer_vendor_id';
  static const String _prefProductIdKey = 'usb_printer_product_id';

  /// USB chunk size for print writes (4 KB).
  ///
  /// USB thermal printers have finite hardware buffers (typically 4–64 KB).
  /// Sending the entire receipt in one monolithic bulk transfer can exceed
  /// the buffer when printing combo deals or orders with many items.
  static const int _usbChunkSize = 4096;

  // ---------------------------------------------------------------------------
  // Device discovery
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getUsbDevices() async {
    try {
      final List<Map<String, dynamic>> results = await FlutterUsbPrinter.getUSBDeviceList();
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

  /// Tries to connect to the previously-saved USB printer.
  ///
  /// * Returns `true` immediately if already connected.
  /// * If a connection is in progress, waits for it to finish (up to 15s).
  /// * Only tries the persisted vendor/product IDs — no blind fallback.
  /// * Returns `false` when no saved printer is found (caller should show
  ///   the printer-selection dialog).
  Future<bool> ensureConnected() async {
    if (_isConnected) {
      debugPrint('UsbPrinterService: already connected');
      return true;
    }

    if (_isConnecting) {
      debugPrint('UsbPrinterService: connection in progress, waiting...');
      int waitedMs = 0;
      while (_isConnecting && waitedMs < 15000) {
        await Future.delayed(const Duration(milliseconds: 300));
        waitedMs += 300;
      }
      if (_isConnected) {
        debugPrint('UsbPrinterService: connected after waiting');
        return true;
      }
      if (_isConnecting) {
        debugPrint('UsbPrinterService: timed out waiting for connection');
        return false;
      }
    }

    _isConnecting = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final String? savedVendorStr = prefs.getString(_prefVendorIdKey);
      final String? savedProductStr = prefs.getString(_prefProductIdKey);

      if (savedVendorStr == null || savedProductStr == null) {
        debugPrint('UsbPrinterService: no saved printer');
        return false;
      }

      final int? savedVendorId = int.tryParse(savedVendorStr);
      final int? savedProductId = int.tryParse(savedProductStr);

      if (savedVendorId == null || savedProductId == null) {
        debugPrint('UsbPrinterService: invalid saved printer IDs');
        return false;
      }

      debugPrint(
        'UsbPrinterService: connecting to saved printer '
        'VID=$savedVendorId PID=$savedProductId',
      );
      return await _usbPrinter.connect(savedVendorId, savedProductId)
          .then((success) {
        if (success == true) {
          _isConnected = true;
          _connectedDevice = {
            'vendorId': savedVendorId.toString(),
            'productId': savedProductId.toString(),
          };
          debugPrint(
            'UsbPrinterService: connected to saved printer '
            'VID=$savedVendorId PID=$savedProductId',
          );
          notifyListeners();
          return true;
        }
        debugPrint(
          'UsbPrinterService: failed to connect to saved printer',
        );
        _isConnected = false;
        _connectedDevice = null;
        notifyListeners();
        return false;
      });
    } catch (e) {
      debugPrint('UsbPrinterService: ensureConnected error: $e');
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
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
  /// * Stores `_connectedDevice` only after a successful connection.
  /// * Resets state on failure.
  /// * Always clears `_isConnecting` in `finally`.
  /// * Calls [notifyListeners] on every state change.
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

        // Persist printer identity for future auto-connect.
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


      final String receiptLabel = '* SALGSKVITTERING *';
      bytes += generator.text(
        stripEmojis(receiptLabel),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );

      final bool isCopy = order['isCopy'] == true;
      final String receiptCopyLabel = '*** KOPI ***';
      if (isCopy) {
        bytes += generator.text(
          stripEmojis(receiptCopyLabel),
          styles: const PosStyles(align: PosAlign.center, bold: true),
        );
      }

      bytes += generator.hr();

      // =====================================================================
      // 1. VENDOR HEADER BLOCK
      // =====================================================================
      final String vendorName = stripEmojis(vendor['name'] as String? ?? 'Restaurant');
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
          stripEmojis(vendor['address'] as String),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['city'] != null) {
        final String zip = stripEmojis(vendor['zipCode'] as String? ?? '');
        bytes += generator.text(
          stripEmojis('${vendor['city']} $zip'.trim()),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['phone'] != null) {
        bytes += generator.text(
          stripEmojis('Tel: ${vendor['phone']}'),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['organizationId'] != null) {
        bytes += generator.text(
          stripEmojis('Org ID: ${vendor['organizationId']}'),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      bytes += generator.hr();

      // =====================================================================
      // 2. RECEIPT META TITLE BLOCK
      // =====================================================================
      bytes += generator.text(
        stripEmojis('Receipt - ${order['orderNumber'] ?? ''}'),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      final String transactionIdStr =
          stripEmojis(order['transactionId']?.toString() ?? '');
      if (transactionIdStr.isNotEmpty) {
        bytes += generator.text(
          stripEmojis('Transaction ID: $transactionIdStr'),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      final String createdAtStr =
          order['createdAt']?.toString() ?? DateTime.now().toIso8601String();
      try {
        final DateTime dt = parsePrinterTimestamp(createdAtStr);
        const List<String> months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        final String formattedDate =
            '${dt.day.toString().padLeft(2, '0')} '
            '${months[dt.month - 1]} ${dt.year} '
            'at ${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}:'
            '${dt.second.toString().padLeft(2, '0')}';
            // '${dt.millisecond.toString().padLeft(3, '0')}';
        bytes += generator.text(
          formattedDate,
          styles: const PosStyles(align: PosAlign.center),
        );
      } catch (_) {
        bytes += generator.text(
          stripEmojis(createdAtStr),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      bytes += generator.hr();

      // =====================================================================
      // 3. ORDER DATA BLOCK (Key-Value Rows)
      // =====================================================================
      bytes += generator.row([
        PosColumn(text: 'Order Type:', width: 6),
        PosColumn(
          text: stripEmojis('${order['orderType'] ?? ''}'.toUpperCase()),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Payment:', width: 6),
        PosColumn(
          text: stripEmojis('${order['paymentMethod'] ?? ''}'.toUpperCase()),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Cashier :', width: 6),
        PosColumn(
          text: stripEmojis('${order['cashierName'] ?? '-'}'),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Terminal :', width: 6),
        PosColumn(
          text: stripEmojis('${order['posDeviceId'] ?? order['deviceId'] ?? ''}'),
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
          itemName = stripEmojis(menuItemField['name']?.toString() ?? '');
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
                choicesList.map((c) => stripEmojis(c['name']?.toString() ?? '')).join(', ');
            bytes += generator.text(
              stripEmojis('  ${og['groupName']}: $choicesStr'),
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
              stripEmojis('  $subPrefix${sub['name'] ?? ''}'),
              styles: const PosStyles(align: PosAlign.left),
            );

            final List? subOpts = sub['selectedOptions'] as List?;
            if (subOpts != null && subOpts.isNotEmpty) {
              for (var subOg in subOpts) {
                final List choicesList = subOg['choices'] as List? ?? [];
                final String choicesStr = choicesList
                    .map((c) => stripEmojis(c['name']?.toString() ?? ''))
                    .join(', ');
                bytes += generator.text(
                  stripEmojis('    ${subOg['groupName']}: $choicesStr'),
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
          (order['totalWithoutVat'] as num? ?? 0.0).toDouble();
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
      // 7b. CASH PAYMENT DETAILS
      // =====================================================================
      final String paymentMethodStr =
          order['paymentMethod']?.toString().toLowerCase() ?? '';
      final double cashReceived =
          (order['cashReceived'] as num? ?? 0.0).toDouble();
      final double cashChange =
          (order['cashChange'] as num? ?? 0.0).toDouble();

      if (paymentMethodStr == 'cash' && cashReceived > 0) {
        bytes += generator.row([
          PosColumn(text: 'Cash Received', width: 6),
          PosColumn(
            text: 'kr ${cashReceived.toStringAsFixed(2)}',
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
        bytes += generator.row([
          PosColumn(text: 'Change', width: 6),
          PosColumn(
            text: 'kr ${cashChange.toStringAsFixed(2)}',
            width: 6,
            styles: const PosStyles(
              align: PosAlign.right,
              bold: true,
            ),
          ),
        ]);
        bytes += generator.hr();
      }

      // =====================================================================
      // 7c. CARD TRANSACTION DETAILS (AID, TVR, TSI, REF)
      // =====================================================================
      final Map<String, dynamic>? transaction =
          order['transaction'] as Map<String, dynamic>?;

      if (paymentMethodStr == 'card' && transaction != null) {
        final String? aid = transaction['aid']?.toString();
        final String? tvr = transaction['tvr']?.toString();
        final String? tsi = transaction['tsi']?.toString();
        final String? ref = transaction['ref']?.toString();
        final String? authResult = transaction['authResult']?.toString();

        if (aid != null && aid.isNotEmpty) {
          bytes += generator.row([
            PosColumn(text: 'AID', width: 4),
            PosColumn(
              text: stripEmojis(aid),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (tvr != null && tvr.isNotEmpty) {
          bytes += generator.row([
            PosColumn(text: 'TVR', width: 4),
            PosColumn(
              text: stripEmojis(tvr),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (tsi != null && tsi.isNotEmpty) {
          bytes += generator.row([
            PosColumn(text: 'TSI', width: 4),
            PosColumn(
              text: stripEmojis(tsi),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (ref != null && ref.isNotEmpty) {
          bytes += generator.row([
            PosColumn(text: 'REF', width: 4),
            PosColumn(
              text: stripEmojis(ref),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (authResult != null && authResult.isNotEmpty) {
          bytes += generator.row([
            PosColumn(text: 'Auth', width: 4),
            PosColumn(
              text: stripEmojis(authResult),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        bytes += generator.hr();
      }

      // =====================================================================
      // 8. FOOTER / BRANDING BLOCK
      // =====================================================================
      final Map<String, dynamic> vendorOthers =
          vendor['others'] as Map<String, dynamic>? ?? {};
      final String receiptMessage =
          vendorOthers['receiptMessage'] as String? ?? 'Takk for deres besøk!';

      bytes += generator.text(
        stripEmojis(receiptMessage),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      // bytes += generator.text(
      //   stripEmojis(vendorName),
      //   styles: const PosStyles(align: PosAlign.center),
      // );

      if (vendor['website'] != null &&
          (vendor['website'] as String).trim().isNotEmpty) {
        bytes += generator.text(
          stripEmojis(vendor['website'] as String),
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
      // 10. CHUNKED USB WRITE – AVOID PRINTER BUFFER OVERFLOW
      // =====================================================================
      //
      // USB thermal printers have finite hardware buffers (typically 4–64 KB).
      // Sending the entire receipt in one monolithic bulk transfer can exceed
      // the buffer when printing combo deals or orders with many items,
      // causing silent print failures.
      //
      // Splitting the payload into 4 KB chunks and adding a short delay
      // between writes lets the printer process each chunk before receiving
      // the next, preventing buffer overruns.
      // =====================================================================

      // 4 KB chunks – well within the buffer of virtually all thermal printers.
      const int chunkSize = _usbChunkSize;

      debugPrint(
        'UsbPrinterService: sending ${bytes.length} bytes in '
        '${(bytes.length / chunkSize).ceil()} chunk(s) to USB printer '
        '(drawer: $openDrawer)',
      );

      bool? writeResult;
      try {
        for (int offset = 0; offset < bytes.length; offset += chunkSize) {
          final int end = (offset + chunkSize > bytes.length)
              ? bytes.length
              : offset + chunkSize;
          final List<int> chunk = bytes.sublist(offset, end);

          final bool? chunkResult =
              await _usbPrinter.write(Uint8List.fromList(chunk));

          if (chunkResult != true) {
            debugPrint(
              'UsbPrinterService: USB write failed at chunk '
              '${(offset / chunkSize).floor() + 1} '
              '(offset $offset, size ${chunk.length})',
            );
            writeResult = false;
            break;
          }

          // Small delay between chunks so the printer can drain its buffer.
          if (end < bytes.length) {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }
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
