import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/printer_service.dart';
import '../widgets/printer_selection_dialog.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController controller;
  final PrinterService _printerService = PrinterService();

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

            switch (data['type']) {
              case 'CHECK_PRINTER':
                _printBill(data);
                break;
              case 'PRINT_BILL':
                _printBill(data);
                break;
              default:
                debugPrint(
                  'Unknown action: ${data['type']}',
                );
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

  void _printBill(Map<String, dynamic> data) async {
    if (!_printerService.isConnected) {
      bool? connected = await showDialog<bool>(
        context: context,
        builder: (context) => const PrinterSelectionDialog(),
      );
      if (connected != true) return;
    }
    await _printerService.printBill(data);
  }

  void _showPrinterSettings() {
    showDialog(
      context: context,
      builder: (context) => const PrinterSelectionDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Betalia Cashier'),
          actions: [
            ListenableBuilder(
              listenable: _printerService,
              builder: (context, _) {
                return IconButton(
                  icon: Icon(
                    Icons.print,
                    color: _printerService.isConnected ? Colors.green : Colors.grey,
                  ),
                  onPressed: _showPrinterSettings,
                );
              },
            ),
          ],
        ),

        backgroundColor: Colors.white,
        body: SafeArea(
          top: false,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 0),
                child: WebViewWidget(controller: controller),
              ),
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
