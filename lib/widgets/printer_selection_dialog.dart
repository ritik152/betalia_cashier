import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import '../services/printer_service.dart';

class PrinterSelectionDialog extends StatefulWidget {
  const PrinterSelectionDialog({super.key});

  @override
  State<PrinterSelectionDialog> createState() => _PrinterSelectionDialogState();
}

class _PrinterSelectionDialogState extends State<PrinterSelectionDialog> {
  final PrinterService _printerService = PrinterService();
  List<fbp.ScanResult> _scanResults = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
    fbp.FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          _scanResults = results;
        });
      }
    });
    fbp.FlutterBluePlus.isScanning.listen((isScanning) {
      if (mounted) {
        setState(() {
          _isScanning = isScanning;
        });
      }
    });
  }

  void _startScan() async {
    try {
      await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    } catch (e) {
      debugPrint("Error starting scan: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Printer'),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: Column(
          children: [
            if (_isScanning) const LinearProgressIndicator(),
            Expanded(
              child: ListView.builder(
                itemCount: _scanResults.length,
                itemBuilder: (context, index) {
                  final result = _scanResults[index];
                  final name = result.device.platformName.isEmpty
                      ? result.device.remoteId.str
                      : result.device.platformName;
                  return ListTile(
                    title: Text(name),
                    subtitle: Text(result.device.remoteId.str),
                    onTap: () async {
                      bool success = await _printerService.connectToDevice(result.device);
                      if (success) {
                        if (mounted) Navigator.pop(context, true);
                      } else {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Failed to connect to printer')),
                          );
                        }
                      }
                    },
                  );
                },
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
          onPressed: _isScanning ? null : _startScan,
          child: const Text('Rescan'),
        ),
      ],
    );
  }
}
