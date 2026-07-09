import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  // Terminal configuration
  String _terminalIpAddress = '';
  String _terminalPort = '';

  @override
  void initState() {
    super.initState();

    // Load saved IP and auto-connect on startup
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'NativeBridge',
        onMessageReceived: (message) {
          try {
            final data = jsonDecode(message.message);

            print("NativeBridge DATA ============ $data");

            switch (data['type']) {
              case 'CONFIGURE_TERMINAL':
                _configureTerminal(data);
                break;
              case 'PAYMENT':
                _startPayment(data);
                break;
              case 'PRINT':
                _printBill(data);
                break;
              default:
                debugPrint('Unknown NativeBridge action: ${data['type']}');
            }
          } catch (e) {
            debugPrint('Invalid JSON from NativeBridge: $e');
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
        Uri.parse('http://10.0.2.2:3000/bakeri/cashier/login'),
      );
  }



  /// Configures the Verifone P630 terminal IP and initializes the connection.
  void _configureTerminal(Map<String, dynamic> data) async {
    final ip = (data['payload']?['ipAddress'] ?? data['ipAddress'] ?? '').toString();
    // final port = (data['payload']?['port'] ?? data['port'] ?? '').toString();

    // If no IP provided, try auto-discovery on the native side

    _terminalIpAddress = ip;
    // _terminalPort = port;

    try {
      final String result = await platform.invokeMethod('configureTerminal', {
        'ipAddress': ip,
        // 'port': port,
      });

      debugPrint('Terminal configured: $result');

      _sendToWebView('onTerminalStatus', {
        'status': result,
        'ipAddress': ip,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verifone: $result'),
            backgroundColor: result == 'CONNECTED' ? Colors.green : Colors.orange,
          ),
        );
      }
    } on PlatformException catch (e) {
      debugPrint('Terminal configure error: ${e.message}');
      _sendToWebView('onTerminalStatus', {
        'status': 'ERROR',
        'message': e.message,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verifone Error: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ================================================================
  // PAYMENT PROCESSING (Verifone P630)
  // ================================================================

  void _startPayment(Map<String, dynamic> data) async {
    try {
      // CHECK TERMINAL STATUS FIRST — prevent crash when not connected
      final String statusJson = await platform.invokeMethod('checkTerminalStatus');
      final statusResult = jsonDecode(statusJson);
      final connected = statusResult['status'] == 'CONNECTED';

      if (!connected) {
        debugPrint('Payment blocked — terminal not connected');
        _sendToWebView('onPaymentResult', {
          'success': false,
          'status': 'NOT_CONNECTED',
          'error': 'Terminal not connected. Please configure the P630 first.',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Terminal not connected. Cannot process payment.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Extract amount from payload - supports various data shapes from the webview
      final payload = data['payload'] ?? data;
      final amount = (payload['amount'] ?? payload['totalAmount'] ?? payload['totalPrice'] ?? 0.0).toDouble();
      final currency = (payload['currency'] ?? 'NOK').toString();

      if (amount <= 0) {
        debugPrint('Invalid payment amount: $amount');
        _sendToWebView('onPaymentResult', {
          'success': false,
          'error': 'Invalid payment amount',
        });
        return;
      }

      debugPrint('Starting Verifone payment: $amount $currency');

      final String resultJson = await platform.invokeMethod('startTransaction', {
        'amount': amount,
        'currency': currency,
      });

      final result = jsonDecode(resultJson);
      debugPrint('Payment result: $result');

      _sendToWebView('onPaymentResult', {
        'success': result['status'] == 'APPROVED',
        'status': result['status'],
        'authResult': result['authResult'],
        'transactionId': result['transactionId'],
        'rrn': result['rrn'],
      });

      if (mounted) {
        final approved = result['status'] == 'APPROVED';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approved ? 'PAYMENT APPROVED ✓' : 'Payment: ${result['status']}'),
            backgroundColor: approved ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } on PlatformException catch (e) {
      debugPrint('Payment PlatformException: ${e.code} - ${e.message}');
      _sendToWebView('onPaymentResult', {
        'success': false,
        'error': e.message,
        'code': e.code,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment Error: ${e.message}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('Payment unexpected error: $e');
      _sendToWebView('onPaymentResult', {
        'success': false,
        'error': e.toString(),
      });
    }
  }




  // ================================================================
  // PRINTER LOGIC
  // ================================================================


  void _printBill(Map<String, dynamic> data) async {
    try {
      if (!_printerService.isConnected && !_usbPrinterService.isConnected) {
        bool? connected = await showDialog<bool>(
          context: context,
          builder: (context) => const PrinterSelectionDialog(),
        );
        if (connected != true) {
          _sendToWebView('onPrintResult', {
            'success': false,
            'error': 'No printer selected',
          });
          return;
        }
      }

      bool success = false;
      if (_printerService.isConnected) {
        success = await _printerService.printBill(data);
      } else if (_usbPrinterService.isConnected) {
        success = await _usbPrinterService.printBill(data);
      } else {
        _sendToWebView('onPrintResult', {
          'success': false,
          'error': 'Printer disconnected',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No printer connected'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      if (success) {
        _sendToWebView('onPrintResult', {'success': true});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Receipt printed successfully'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        _sendToWebView('onPrintResult', {
          'success': false,
          'error': 'Failed to send print data',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Print failed. Please check printer.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Print error: $e');
      _sendToWebView('onPrintResult', {
        'success': false,
        'error': e.toString(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Print error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ================================================================
  // WEBVIEW COMMUNICATION HELPERS
  // ================================================================

  /// Sends a JSON message back to the WebView via a global JS function.
  void _sendToWebView(String functionName, Map<String, dynamic> data) {
    try {
      final safeJson = jsonEncode(data);
      // Escape for safe injection into JS string
      final escaped = safeJson.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n');
      controller.runJavaScript(
        "try { if(window.$functionName) window.$functionName('$escaped'); } catch(e) { console.error('$functionName callback error:', e); }",
      );
    } catch (e) {
      debugPrint('Error calling $functionName in WebView: $e');
    }
  }

  // ================================================================
  // BUILD
  // ================================================================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
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