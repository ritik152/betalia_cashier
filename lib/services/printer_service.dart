import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

class PrinterService extends ChangeNotifier {
  static final PrinterService _instance = PrinterService._internal();
  factory PrinterService() => _instance;
  PrinterService._internal();

  fbp.BluetoothDevice? _connectedDevice;
  fbp.BluetoothCharacteristic? _writeCharacteristic;

  bool get isConnected => _connectedDevice != null && _writeCharacteristic != null;
  String? get connectedDeviceName => _connectedDevice?.platformName ?? _connectedDevice?.remoteId.str;

  Future<bool> connectToDevice(fbp.BluetoothDevice device) async {
    try {
      await device.connect();
      _connectedDevice = device;

      List<fbp.BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.write || characteristic.properties.writeWithoutResponse) {
            _writeCharacteristic = characteristic;
            break;
          }
        }
        if (_writeCharacteristic != null) break;
      }

      notifyListeners();
      return _writeCharacteristic != null;
    } catch (e) {
      print("Error connecting to printer: $e");
      return false;
    }
  }

  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _writeCharacteristic = null;
    notifyListeners();
  }


  Future<bool> printBill(Map<String, dynamic> data) async {
    // 1. Bluetooth Connection Check
    if (_writeCharacteristic == null) {
      debugPrint("PrinterService: No Bluetooth printer connected");
      return false;
    }

    // 2. Safe parsing of nested structures
    final Map<String, dynamic> order = data['order'] as Map<String, dynamic>? ?? {};
    final Map<String, dynamic> vendor = data['vendor'] as Map<String, dynamic>? ?? {};

    if (order.isEmpty && vendor.isEmpty) {
      debugPrint("PrinterService: Receipt dataset payload is completely empty.");
      return false;
    }

    try {
      final profile = await CapabilityProfile.load();
      // Keeps your specific 58mm sizing structure for the Bluetooth mobile hardware
      final generator = Generator(PaperSize.mm58, profile);
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
        PosColumn(text: '${order['orderType'] ?? ''}'.toUpperCase(), width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Payment:', width: 6),
        PosColumn(text: '${order['paymentMethod'] ?? ''}'.toUpperCase(), width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Cashier :', width: 6),
        PosColumn(text: '${order['cashierName'] ?? '-'}', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
      bytes += generator.row([
        PosColumn(text: 'Terminal:', width: 6),
        PosColumn(text: '${order['deviceId'] ?? ''}', width: 6, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);

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

        double price = (item['price'] as num? ?? 0.0).toDouble();
        final int qty = (item['quantity'] as num? ?? 1).toInt();
        final double computedTotalPrice = price * qty;

        String itemName = '';
        if (item['menuItemId'] != null && item['menuItemId'] is Map) {
          final Map<dynamic, dynamic> menuItemField = item['menuItemId'] as Map;
          itemName = menuItemField['name']?.toString() ?? '';
        }

        bytes += generator.row([
          PosColumn(text: itemName, width: 7),
          PosColumn(text: '$qty', width: 2, styles: const PosStyles(align: PosAlign.center)),
          PosColumn(text: computedTotalPrice.toStringAsFixed(2), width: 3, styles: const PosStyles(align: PosAlign.right)),
        ]);

        final List? selectedOptions = item['selectedOptions'] as List?;
        final List? subItems = item['subItems'] as List?;

        // Options rendering fallback
        if (selectedOptions != null && selectedOptions.isNotEmpty && (subItems == null || subItems.isEmpty)) {
          for (var og in selectedOptions) {
            final List choicesList = og['choices'] as List? ?? [];
            final String choicesStr = choicesList.map((c) => c['name']?.toString() ?? '').join(', ');
            bytes += generator.text('  ${og['groupName']}: $choicesStr', styles: const PosStyles(align: PosAlign.left));
          }
        }

        // Modifiers (Subitems rendering matching the receipt screenshot)
        if (subItems != null && subItems.isNotEmpty) {
          for (var subDynamic in subItems) {
            final Map<String, dynamic> sub = subDynamic as Map<String, dynamic>;
            final int subQty = (sub['quantity'] as num? ?? 1).toInt();
            final String subPrefix = subQty > 1 ? '${subQty}x ' : '';

            bytes += generator.text('  $subPrefix${sub['name'] ?? ''}', styles: const PosStyles(align: PosAlign.left));

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
      // 6. GRAND TOTAL ROW
      // ==========================================
      final double totalPrice = (order['totalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row([
        PosColumn(text: 'TOTAL', width: 5, styles: const PosStyles(bold: true, height: PosTextSize.size2, width: PosTextSize.size1)),
        PosColumn(text: 'kr ${totalPrice.toStringAsFixed(2)}', width: 7, styles: const PosStyles(align: PosAlign.right, bold: true, height: PosTextSize.size2, width: PosTextSize.size1)),
      ]);

      bytes += generator.hr();

      // ==========================================
      // 7. TAXES SUMMARY
      // ==========================================
      final double subtotalPrice = (order['subtotalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row([
        PosColumn(text: 'Subtotal', width: 6),
        PosColumn(text: 'kr ${subtotalPrice.toStringAsFixed(2)}', width: 6, styles: const PosStyles(align: PosAlign.right)),
      ]);

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

      final String createdAtStr = order['createdAt']?.toString() ?? DateTime.now().toIso8601String();
      try {
        final DateTime dt = DateTime.parse(createdAtStr);
        final List<String> months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        final String formattedDate = "${dt.day.toString().padLeft(2, '0')} ${months[dt.month - 1]} ${dt.year} at ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
        bytes += generator.text(formattedDate, styles: const PosStyles(align: PosAlign.center));
      } catch (_) {
        bytes += generator.text(createdAtStr, styles: const PosStyles(align: PosAlign.center));
      }

      if (vendor['website'] != null && vendor['website'].toString().trim().isNotEmpty) {
        bytes += generator.text(vendor['website'].toString(), styles: const PosStyles(align: PosAlign.center));
      }

      bytes += generator.feed(2);
      bytes += generator.cut();

      // 3. Bluetooth Execution Payload Method Hand-off
      await _sendBytes(bytes);
      debugPrint("PrinterService: Receipt sent to Bluetooth printer successfully");
      return true;

    } catch (e) {
      debugPrint("PrinterService: Error printing receipt over Bluetooth: $e");
      return false;
    }
  }
  /// Prints a receipt to the connected Bluetooth thermal printer.
  /// Returns true if the print was sent successfully, false otherwise.
  /*Future<bool> printBill(Map<String, dynamic> data) async {
    if (_writeCharacteristic == null) {
      debugPrint("PrinterService: No Bluetooth printer connected");
      return false;
    }

    if (data.isEmpty) {
      debugPrint("PrinterService: Empty receipt data - nothing to print");
      return false;
    }

    try {
      final profile = await CapabilityProfile.load();
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

      await _sendBytes(bytes);
      debugPrint("PrinterService: Receipt sent to Bluetooth printer successfully");
      return true;
    } catch (e) {
      debugPrint("PrinterService: Error printing receipt: $e");
      return false;
    }
  }*/

  Future<void> _sendBytes(List<int> bytes) async {
    if (_writeCharacteristic == null) return;

    // Send in chunks to avoid BLE MTU issues
    const int chunkSize = 20;
    for (int i = 0; i < bytes.length; i += chunkSize) {
      try {
        int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        await _writeCharacteristic!.write(bytes.sublist(i, end), withoutResponse: true);
      } catch (e) {
        debugPrint("PrinterService: BLE write chunk failed at offset $i: $e");
        // Continue with next chunk to avoid crashing the app
      }
    }
  }
}

