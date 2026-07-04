import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_usb_printer/flutter_usb_printer.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

class UsbPrinterService extends ChangeNotifier {
  static final UsbPrinterService _instance = UsbPrinterService._internal();
  factory UsbPrinterService() => _instance;
  UsbPrinterService._internal();

  final FlutterUsbPrinter _usbPrinter = FlutterUsbPrinter();
  bool _isConnected = false;
  Map<String, dynamic>? _connectedDevice;

  bool get isConnected => _isConnected;
  String? get connectedDeviceName => _connectedDevice?['productName'] ?? _connectedDevice?['deviceName'];

  Future<List<Map<String, dynamic>>> getUsbDevices() async {
    try {
      List<Map<String, dynamic>> results = await FlutterUsbPrinter.getUSBDeviceList();
      print("USB Devices found: ${results.length}");
      return results;
    } catch (e) {
      debugPrint("Error getting USB devices: $e");
      return [];
    }
  }

  Future<bool> connectToDevice(Map<String, dynamic> device) async {
    try {
      final int vendorId = int.parse(device['vendorId'].toString());
      final int productId = int.parse(device['productId'].toString());
      
      bool? success = await _usbPrinter.connect(vendorId, productId);
      _isConnected = success ?? false;
      if (_isConnected) {
        _connectedDevice = device;
      }
      notifyListeners();
      return _isConnected;
    } on PlatformException catch (e) {
      debugPrint("Platform Error connecting to USB printer: ${e.message}");
      return false;
    } catch (e) {
      debugPrint("Error connecting to USB printer: $e");
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _usbPrinter.close();
    } catch (e) {
      debugPrint("Error closing USB printer: $e");
    }
    _isConnected = false;
    _connectedDevice = null;
    notifyListeners();
  }

  /*Future<void> printBill(Map<String, dynamic> data) async {
    if (!_isConnected) {
      debugPrint("No USB printer connected");
      return;
    }

    // Extract root structures safely matching the complex map payload
    final Map<String, dynamic> order = data['order'] as Map<String, dynamic>? ?? {};
    final Map<String, dynamic> vendor = data['vendor'] as Map<String, dynamic>? ?? {};

    // If payload structure is entirely missing or empty, do nothing or handle gracefully
    if (order.isEmpty && vendor.isEmpty) {
      debugPrint("Receipt dataset payload is completely empty.");
      return;
    }

    try {
      final profile = await CapabilityProfile.load();
      // Use PaperSize.mm80 as shown by the wide layout in "Screenshot 2026-07-04 at 8.05.21 PM.png"
      final generator = Generator(PaperSize.mm80, profile);
      List<int> bytes = [];

      // ==========================================
      // 1. VENDOR HEADER BLOCK
      // ==========================================
      final String vendorName = vendor['name'] ?? 'Restaurant';
      bytes += generator.text(vendorName,
          styles: const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2));

      if (vendor['address'] != null) {
        bytes += generator.text(vendor['address'], styles: const PosStyles(align: PosAlign.center));
      }
      if (vendor['city'] != null) {
        final String zip = vendor['zipCode'] ?? '';
        bytes += generator.text('${vendor['city']} $zip'.trim(), styles: const PosStyles(align: PosAlign.center));
      }
      if (vendor['phone'] != null) {
        bytes += generator.text('Tel: ${vendor['phone']}', styles: const PosStyles(align: PosAlign.center));
      }
      if (vendor['organizationId'] != null) {
        bytes += generator.text('Org ID: ${vendor['organizationId']}', styles: const PosStyles(align: PosAlign.center));
      }

      bytes += generator.hr();

      // ==========================================
      // 2. RECEIPT META TITLE BLOCK
      // ==========================================
      final bool isCopy = order['isCopy'] ?? false;
      final String receiptLabel = isCopy ? 'KOPIKVITTERING' : 'SALGSKVITTERING';
      bytes += generator.text(receiptLabel, styles: const PosStyles(align: PosAlign.center, bold: true));
      bytes += generator.text('Receipt - ${order['orderNumber'] ?? ''}', styles: const PosStyles(align: PosAlign.center, bold: true));

      bytes += generator.hr();

      // ==========================================
      // 3. ORDER DATA BLOCK (Key-Value Rows)
      // ==========================================
      bytes += generator.row([
        PosColumn(text: 'Order Type:', width: 6),
        PosColumn(text: '${order['orderType'] ?? ''}', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Payment:', width: 6),
        PosColumn(text: '${order['paymentMethod'] ?? ''}', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Cashier :', width: 6),
        PosColumn(text: '${order['cashierName'] ?? '-'}', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Terminal:', width: 6),
        PosColumn(text: '${order['deviceId'] ?? ''}', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);

      // Dynamic item count reduce calculation matching template logic
      final List itemsList = order['items'] as List? ?? [];
      int totalItemCount = itemsList.fold<int>(0, (sum, item) {
        return sum + ((item['quantity'] as num?)?.toInt() ?? 0);
      });

      bytes += generator.row([
        PosColumn(text: 'Total Items', width: 6),
        PosColumn(text: '$totalItemCount', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);

      bytes += generator.hr();

      // ==========================================
      // 4. ITEMS GRID HEADERS
      // ==========================================
      bytes += generator.row([
        PosColumn(text: 'Item', width: 7, styles: const PosStyles(bold: true)),
        PosColumn(text: 'Qty', width: 2, styles: const PosStyles(align: PosAlign.center, bold: true)),
        PosColumn(text: 'Price', width: 3, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);

      // ==========================================
      // 5. PRINTING DYNAMIC ITEMS & SUBITEMS
      // ==========================================
      for (var itemDynamic in itemsList) {
        final Map<String, dynamic> item = itemDynamic as Map<String, dynamic>;

        // Compute dynamic single item base price based on rules
        double price = 0.0;
        if (item['discountPrice'] != null && (item['discountPrice'] as num) > 0) {
          price = (item['discountPrice'] as num).toDouble();
        } else {
          price = (item['price'] as num? ?? 0.0).toDouble();
        }
        if (order['orderType'] == 'dine') {
          price = (price / 1.15) * 1.25;
        }

        final int qty = (item['quantity'] as num? ?? 1).toInt();
        final double computedTotalPrice = price * qty;

        // Resolve safe product display name string
        String itemName = '';
        if (item['menuItemId'] is Map) {
          itemName = item['menuItemId']['name']?.toString() ?? '';
        }

        // Root item row
        bytes += generator.row([
          PosColumn(text: itemName, width: 7),
          PosColumn(text: '$qty', width: 2, styles: const PosStyles(align: PosAlign.center)),
          PosColumn(text: computedTotalPrice.toStringAsFixed(2), width: 3, styles: const PosStyles(align: PosAlign.right)),
        ]);

        // Print nested Options if SubItems are absent
        final List? selectedOptions = item['selectedOptions'] as List?;
        final List? subItems = item['subItems'] as List?;

        if (selectedOptions != null && selectedOptions.isNotEmpty && (subItems == null || subItems.isEmpty)) {
          for (var og in selectedOptions) {
            final List choicesList = og['choices'] as List? ?? [];
            final String choicesStr = choicesList.map((c) => c['name']?.toString() ?? '').join(', ');
            bytes += generator.text('  ${og['groupName']}: $choicesStr', styles: const PosStyles(align: PosAlign.left));
          }
        }

        // Print structured SubItems matching image layout rules
        if (subItems != null && subItems.isNotEmpty) {
          for (var subDynamic in subItems) {
            final Map<String, dynamic> sub = subDynamic as Map<String, dynamic>;
            final int subQty = (sub['quantity'] as num? ?? 1).toInt();
            final String subPrefix = subQty > 1 ? '${subQty}x ' : '';

            bytes += generator.text('  $subPrefix${sub['name'] ?? ''}', styles: const PosStyles(align: PosAlign.left));

            // Nested Subitem options formatting
            final List? subOpts = sub['selectedOptions'] as List?;
            if (subOpts != null && subOpts.isNotEmpty) {
              for (var subOg in subOpts) {
                final List choicesList = subOg['choices'] as List? ?? [];
                final String choicesStr = choicesList.map((c) => c['name']?.toString() ?? '').join(', ');
                bytes += generator.text('    ${subOg['groupName']}: $choicesStr', styles: const PosStyles(align: PosAlign.left));
              }
            }
          }
        }
      }

      bytes += generator.hr();

      // ==========================================
      // 6. GRAND TOTAL ROW (Large text display)
      // ==========================================
      final double totalPrice = (order['totalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row([
        PosColumn(text: 'TOTAL', width: 5, styles: const PosStyles(bold: true, height: PosTextSize.size2, width: PosTextSize.size1)),
        PosColumn(text: 'kr ${totalPrice.toStringAsFixed(2)}', width: 7, styles: const PosStyles(align: PosAlign.right, bold: true, height: PosTextSize.size2, width: PosTextSize.size1)),
      ]);

      bytes += generator.hr();

      // ==========================================
      // 7. TAXES & ACCUMULATIVE DISCOUNTS SUMMARY
      // ==========================================
      final double subtotalPrice = (order['subtotalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row([
        PosColumn(text: 'Subtotal', width: 6),
        PosColumn(text: 'kr ${subtotalPrice.toStringAsFixed(2)}', width: 6, styles: const PosStyles(align: PosAlign.right)),
      ]);

      // Handle conditional tax processing
      final double vatPrice = (order['vatPrice'] as num? ?? 0.0).toDouble();
      if (vatPrice > 0) {
        final Map<String, double> vatRates = {'takeaway': 0.15, 'dine': 0.25, 'delivery': 0.15};
        final double ratePercent = (vatRates[order['orderType']] ?? 0.15) * 100;

        bytes += generator.row([
          PosColumn(text: 'VAT (${ratePercent.toStringAsFixed(0)}%)', width: 6),
          PosColumn(text: 'kr ${vatPrice.toStringAsFixed(2)}', width: 6, styles: const PosStyles(align: PosAlign.right)),
        ]);
      }

      bytes += generator.hr();

      // ==========================================
      // 8. FOOTER / BRANDING BLOCK
      // ==========================================
      final Map<String, dynamic> vendorOthers = vendor['others'] as Map<String, dynamic>? ?? {};
      final String receiptMessage = vendorOthers['receiptMessage'] ?? 'Takk for deres besøk!';

      bytes += generator.text(receiptMessage, styles: const PosStyles(align: PosAlign.center, bold: true));
      bytes += generator.text(vendorName, styles: const PosStyles(align: PosAlign.center));

      // Formatting date string display dynamically
      final String createdAtStr = order['createdAt']?.toString() ?? DateTime.now().toIso8601String();
      try {
        final DateTime dt = DateTime.parse(createdAtStr);
        // Converts ISO string to: "04 Jul 2026, 14:27" layout directly matching the image
        final List<String> months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        final String formattedDate = "${dt.day.toString().padLeft(2, '0')} ${months[dt.month - 1]} ${dt.year}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
        bytes += generator.text(formattedDate, styles: const PosStyles(align: PosAlign.center));
      } catch (_) {
        bytes += generator.text(createdAtStr, styles: const PosStyles(align: PosAlign.center));
      }

      // Print trailing website link line if explicitly initialized
      if (vendor['website'] != null && vendor['website'].toString().trim().isNotEmpty) {
        bytes += generator.text(vendor['website'].toString(), styles: const PosStyles(align: PosAlign.center));
      }

      bytes += generator.feed(3);
      bytes += generator.cut();

      // Output raw structural byte buffers directly down to the serial device channel stream
      await _usbPrinter.write(Uint8List.fromList(bytes));
      await Future.delayed(const Duration(milliseconds: 500));

    } on PlatformException catch (e) {
      debugPrint("Platform Error writing to USB printer: ${e.message}");
    } catch (e) {
      debugPrint("Error printing USB bill: $e");
    }
  }*/
  Future<void> printBill(Map<String, dynamic> data) async {
    if (!_isConnected) {
      debugPrint("No USB printer connected");
      return;
    }

    // --- STATIC TESTING DATA ---
    // If the passed data is empty or missing items, populate it with mock receipt data
    if (data.isEmpty || data['items'] == null) {
      data = {
        'order_id': 'BTL-USB-9874',
        'items': [
          {'name': 'Double Cheeseburger', 'qty': 2, 'total': 15.00},
          {'name': 'Large French Fries', 'qty': 1, 'total': 4.50},
          {'name': 'Vanilla Milkshake', 'qty': 2, 'total': 8.00},
          {'name': 'Extra Dipping Sauce', 'qty': 3, 'total': 1.50},
        ],
        'total_amount': 29.00
      };
    }
    // ---------------------------

    try {
      final profile = await CapabilityProfile.load();
      // Most small USB thermal printers use 58mm paper.
      // If your printer is the larger 80mm type, change mm58 to mm80.
      final generator = Generator(PaperSize.mm58, profile); 
      List<int> bytes = [];

      // Receipt Header
      bytes += generator.text('BETALIA CASHIER',
          styles: const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2));
      if (data['order_id'] != null) {
        bytes += generator.text('Order ID: ${data['order_id']}', styles: const PosStyles(align: PosAlign.center));
      }
      bytes += generator.hr();

      // Items Header
      bytes += generator.row([
        PosColumn(text: 'Item', width: 7, styles: const PosStyles(bold: true)),
        PosColumn(text: 'Qty', width: 2, styles: const PosStyles(align: PosAlign.right, bold: true)),
        PosColumn(text: 'Total', width: 3, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);

      // Printing Items List
      if (data['items'] != null && data['items'] is List) {
        for (var item in data['items']) {
          bytes += generator.row([
            PosColumn(text: item['name'] ?? '', width: 7),
            PosColumn(text: '${item['qty'] ?? 1}', width: 2, styles: const PosStyles(align: PosAlign.right)),
            PosColumn(text: '${item['total'] ?? 0.0}', width: 3, styles: const PosStyles(align: PosAlign.right)),
          ]);
        }
      }

      bytes += generator.hr();

      // Total
      bytes += generator.row([
        PosColumn(text: 'TOTAL', width: 8, styles: const PosStyles(bold: true)),
        PosColumn(text: '${data['total_amount'] ?? 0.0}', width: 4, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);

      bytes += generator.feed(2);
      bytes += generator.cut();

      await _usbPrinter.write(Uint8List.fromList(bytes));

      await Future.delayed(const Duration(milliseconds: 500));

    } on PlatformException catch (e) {
      debugPrint("Platform Error writing to USB printer: ${e.message}");
    } catch (e) {
      debugPrint("Error printing USB bill: $e");
    }
  }
}
