import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/printer_service.dart';
import '../services/usb_printer_service.dart';
import '../widgets/printer_selection_dialog.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  static const platform = MethodChannel('com.betalia.payments/p630');
  late final WebViewController controller;
  final PrinterService _printerService = PrinterService();
  final UsbPrinterService _usbPrinterService = UsbPrinterService();

  bool isLoading = true;

  @override
  void initState() {
    super.initState();

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'NativeBridge',
        onMessageReceived: (message) {
          try {
            final data = jsonDecode(message.message);

            print("DATA ============ $data");

            switch (data['type']) {
              case 'CHECK_PRINTER':
                _checkVerifoneStatus();
                break;
              case 'PRINT':
                _startPayment(data);
                // _printBill(data);
                break;
              case 'PAYMENT':
                _startPayment(data);
                break;
              default:
                debugPrint('Unknown action: ${data['type']}');
            }
          } catch (e) {
            debugPrint('Invalid JSON: $e');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            setState(() {
              isLoading = false;
            });
          },
        ),
      )
      ..loadRequest(
        Uri.parse('https://betalia.no/bakeri/cashier/login'),
      );
  }

  void _checkVerifoneStatus() async {
    try {
      final String result = await platform.invokeMethod('checkTerminalStatus');
      // Send result back to WebView
      controller.runJavaScript('if(window.onVerifoneStatus) window.onVerifoneStatus("$result")');
      
      // Also show a snackbar for testing
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verifone Status: $result')),
        );
      }
    } on PlatformException catch (e) {
      controller.runJavaScript('if(window.onVerifoneStatus) window.onVerifoneStatus("ERROR: ${e.message}")');
    }
  }

  void _startPayment(Map<String, dynamic> data) async {
    try {
      final String result = await platform.invokeMethod('startTransaction', {
        'amountInCents': /*data['amountInCents'] ??*/ 5,
        'currency': /*data['currency'] ?? */'NOK',
      });
      controller.runJavaScript('if(window.onPaymentResult) window.onPaymentResult(true, "$result")');
    } on PlatformException catch (e) {
      controller.runJavaScript('if(window.onPaymentResult) window.onPaymentResult(false, "${e.message}")');
    }
  }

  void _checkPrinterStatus() {
    final isConnected = _printerService.isConnected || _usbPrinterService.isConnected;
    controller.runJavaScript('if(window.onPrinterStatus) window.onPrinterStatus($isConnected)');
  }

  void _printBill(Map<String, dynamic> data) async {
    if (!_printerService.isConnected && !_usbPrinterService.isConnected) {
      bool? connected = await showDialog<bool>(
        context: context,
        builder: (context) => const PrinterSelectionDialog(),
      );
      if (connected != true) return;
    }

    if (_printerService.isConnected) {
      await _printerService.printBill(data);
    } else if (_usbPrinterService.isConnected) {
      await _usbPrinterService.printBill(data);
    }
  }

  void _showPrinterSettings() {
    if (_printerService.isConnected || _usbPrinterService.isConnected) {
      final name = _printerService.isConnected 
          ? _printerService.connectedDeviceName 
          : _usbPrinterService.connectedDeviceName;
      final type = _printerService.isConnected ? "Bluetooth" : "USB";

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Printer Connected'),
          content: Text('Connected to: $name ($type)'),
          actions: [
            TextButton(
              onPressed: () {
                _printerService.disconnect();
                _usbPrinterService.disconnect();
                Navigator.pop(context);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Disconnect'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (context) => const PrinterSelectionDialog(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        // appBar: AppBar(
        //   title: const Text('Betalia Cashier'),
        //   actions: [
        //     ListenableBuilder(
        //       listenable: Listenable.merge([_printerService, _usbPrinterService]),
        //       builder: (context, _) {
        //         final isConnected = _printerService.isConnected || _usbPrinterService.isConnected;
        //         return IconButton(
        //           icon: Icon(
        //             isConnected ? Icons.print : Icons.print_disabled,
        //             color: isConnected ? Colors.green : Colors.grey,
        //           ),
        //           onPressed: _showPrinterSettings,
        //         );
        //       },
        //     ),
        //   ],
        // ),
        backgroundColor: Colors.white,
        body: SafeArea(
          top: false,
          child: Stack(
            children: [
              WebViewWidget(controller: controller),
              if (isLoading)
                Center(
                  child: Image.asset(
                    "assets/images/app_logo.png",
                    height: 250,
                    width: 250,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

