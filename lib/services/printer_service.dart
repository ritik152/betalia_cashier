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


  /*Future<void> printBill(Map<String, dynamic> data) async {
    if (_writeCharacteristic == null) {
      print("No printer connected");
      return;
    }

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

    // Items
    bytes += generator.row([
      PosColumn(text: 'Item', width: 7, styles: const PosStyles(bold: true)),
      PosColumn(text: 'Qty', width: 2, styles: const PosStyles(align: PosAlign.right, bold: true)),
      PosColumn(text: 'Total', width: 3, styles: const PosStyles(align: PosAlign.right, bold: true)),
    ]);

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
  }*/

  /// Prints a receipt to the connected Bluetooth thermal printer.
  /// Returns true if the print was sent successfully, false otherwise.
  Future<bool> printBill(Map<String, dynamic> data) async {
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
  }

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

