import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import '../services/printer_service.dart';
import '../services/usb_printer_service.dart';

class PrinterSelectionDialog extends StatefulWidget {
  const PrinterSelectionDialog({super.key});

  @override
  State<PrinterSelectionDialog> createState() => _PrinterSelectionDialogState();
}

class _PrinterSelectionDialogState extends State<PrinterSelectionDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final PrinterService _printerService = PrinterService();
  final UsbPrinterService _usbPrinterService = UsbPrinterService();

  List<fbp.ScanResult> _bluetoothResults = [];
  List<Map<String, dynamic>> _usbDevices = [];
  bool _isScanningBluetooth = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _startBluetoothScan();
    _getUsbDevices();

    fbp.FlutterBluePlus.scanResults.listen((results) {
      if (mounted) setState(() => _bluetoothResults = results);
    });
    fbp.FlutterBluePlus.isScanning.listen((isScanning) {
      if (mounted) setState(() => _isScanningBluetooth = isScanning);
    });
  }

  Future<void> _startBluetoothScan() async {
    try {
      await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    } catch (e) {
      debugPrint("Error starting BT scan: $e");
    }
  }

  Future<void> _getUsbDevices() async {
    final devices = await _usbPrinterService.getUsbDevices();
    if (mounted) setState(() => _usbDevices = devices);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Printer'),
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(icon: Icon(Icons.bluetooth), text: "Bluetooth"),
                Tab(icon: Icon(Icons.usb), text: "USB"),
              ],
              labelColor: Theme.of(context).primaryColor,
              unselectedLabelColor: Colors.grey,
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildBluetoothList(),
                  _buildUsbList(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (_tabController.index == 0) {
              _startBluetoothScan();
            } else {
              _getUsbDevices();
            }
          },
          child: const Text('Rescan'),
        ),
      ],
    );
  }

  Widget _buildBluetoothList() {
    return Column(
      children: [
        if (_isScanningBluetooth) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            itemCount: _bluetoothResults.length,
            itemBuilder: (context, index) {
              final result = _bluetoothResults[index];
              final name = result.device.platformName.isEmpty ? result.device.remoteId.str : result.device.platformName;
              return ListTile(
                leading: const Icon(Icons.print),
                title: Text(name),
                subtitle: Text(result.device.remoteId.str),
                onTap: () async {
                  bool success = await _printerService.connectToDevice(result.device);
                  if (success) {
                    if (mounted) Navigator.pop(context, true);
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to connect')));
                    }
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildUsbList() {
    return ListView.builder(
      itemCount: _usbDevices.length,
      itemBuilder: (context, index) {
        final device = _usbDevices[index];
        return ListTile(
          leading: const Icon(Icons.usb),
          title: Text(device['productName'] ?? device['deviceName'] ?? 'Unknown USB Device'),
          subtitle: Text("VID: ${device['vendorId']} PID: ${device['productId']}"),
          onTap: () async {
            bool success = await _usbPrinterService.connectToDevice(device);
            if (success) {
              if (mounted) Navigator.pop(context, true);
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to connect USB')));
              }
            }
          },
        );
      },
    );
  }
}

