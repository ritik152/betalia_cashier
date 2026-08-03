import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../services/usb_printer_service.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  static const platform = MethodChannel('com.betalia.payments/p630');
  late final WebViewController controller;
  final UsbPrinterService _usbPrinterService = UsbPrinterService();

  bool isLoading = true;

  // Terminal configuration
  String _terminalIpAddress = '';
  String _terminalPort = '';

  @override
  void initState() {
    super.initState();

    // Attempt USB printer connection after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _usbPrinterService.ensureConnected();
    });

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'NativeBridge',
        onMessageReceived: (message) {
          try {
            final data = jsonDecode(message.message);

            switch (data['type']) {
              case 'CHECK_TERMINAL_STATUS':
                _checkTerminalStatus();
                break;

              case 'CONFIGURE_TERMINAL':
                _configureTerminal(data);
                break;

              case 'CHANGE_TERMINAL':
                _changeTerminal();
                break;

              case 'PAYMENT':
                _startPayment(data);
                break;

              case 'PRINT':
                _printBill(data);
                break;

              default:
                debugPrint(
                  'Unknown NativeBridge action: ${data['type']}',
                );
            }
          } catch (e) {
            debugPrint('Invalid JSON from NativeBridge: $e');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            if (mounted) {
              setState(() {
                isLoading = false;
              });
            }

            await _autoConnectTerminal();
          },
        ),
      )
      ..loadRequest(
        Uri.parse('http://10.0.2.2:3000/bakeri/cashier'),
      );

    // Configure Android WebView for sharp rendering on tablet screens.
    // The webview_flutter_android plugin defaults useWideViewPort to false,
    // which causes the page to render at a fixed ~980px width and then
    // upscale — producing blurry text and UI elements on high-DPI tablets.
    // Enabling it respects the <meta viewport> tag so the page renders at
    // the native device pixel width with no scaling.
    if (controller.platform is AndroidWebViewController) {
      final androidController =
          controller.platform as AndroidWebViewController;
      androidController.setUseWideViewPort(true);
      androidController.setTextZoom(100);
    }
  }

  // ================================================================
  // TERMINAL STATUS & CONFIGURATION (Verifone P630)
  // ================================================================

  /// Queries the native side for the current terminal status and forwards
  /// it to the web page via `onTerminalStatus`.
  Future<void> _checkTerminalStatus() async {
    try {
      final String statusJson =
          await platform.invokeMethod('checkTerminalStatus');

      final Map<String, dynamic> status =
          jsonDecode(statusJson);

      debugPrint('Terminal status: $status');

      _sendToWebView('onTerminalStatus', status);
    } on PlatformException catch (e) {
      debugPrint(
        'Terminal status error: ${e.code} - ${e.message}',
      );

      _sendToWebView('onTerminalStatus', {
        'status': 'ERROR',
        'code': e.code,
        'message': e.message,
      });
    } catch (e) {
      debugPrint('Terminal status error: $e');

      _sendToWebView('onTerminalStatus', {
        'status': 'ERROR',
        'message': e.toString(),
      });
    }
  }

  /// Configures the Verifone P630 terminal and initializes the connection.
  ///
  /// Requires the IP address, serial number, instance ID and POS device ID.
  /// On success, the terminal details are persisted so the app can
  /// auto-reconnect on the next launch.
  Future<String?> _configureTerminal(
    Map<String, dynamic> data,
  ) async {
    final payload =
        data['payload'] as Map<String, dynamic>? ?? data;

    final ipAddress =
        (payload['ipAddress'] ?? '').toString().trim();

    final serialNumber =
        (payload['serialNumber'] ?? '').toString().trim();

    final instanceId =
        (payload['instanceId'] ?? '').toString().trim();

    final posDeviceId =
        (payload['posDeviceId'] ?? '').toString().trim();

    if (ipAddress.isEmpty ||
        serialNumber.isEmpty ||
        instanceId.isEmpty ||
        posDeviceId.isEmpty) {
      _sendToWebView('onTerminalStatus', {
        'status': 'INVALID_CONFIGURATION',
        'message': 'All terminal fields are required',
      });
      return null;
    }

    // Validate IPv4 format before passing to native (prevents native crash)
    final ipv4RegExp = RegExp(
      r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$',
    );
    if (!ipv4RegExp.hasMatch(ipAddress)) {
      _sendToWebView('onTerminalStatus', {
        'status': 'INVALID_CONFIGURATION',
        'message': 'Invalid IP address. Please enter a valid IPv4 address (e.g., 192.168.1.100).',
      });
      return null;
    }

    _terminalIpAddress = ipAddress;

    try {
      final String result =
          await platform.invokeMethod(
        'configureTerminal',
        {
          'ipAddress': ipAddress,
          'serialNumber': serialNumber,
          'instanceId': instanceId,
          'posDeviceId': posDeviceId,
        },
      ).timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          _sendToWebView('onTerminalStatus', {
            'status': 'TIMEOUT',
            'code': 'CONNECT_TIMEOUT',
            'message': 'Terminal connection timed out. Check the IP address and ensure the terminal is reachable.',
          });
          return 'TIMEOUT';
        },
      );

      if (result == 'TIMEOUT') {
        debugPrint('Terminal configuration timed out');
        return 'TIMEOUT';
      }

      debugPrint('Terminal configured: $result');

      if (result == 'CONNECTED') {
        final preferences =
            await SharedPreferences.getInstance();

        await preferences.setString(
          'terminalIpAddress',
          ipAddress,
        );

        await preferences.setString(
          'terminalSerialNumber',
          serialNumber,
        );

        await preferences.setString(
          'terminalInstanceId',
          instanceId,
        );

        await preferences.setString(
          'terminalPosDeviceId',
          posDeviceId,
        );
      }

      _sendToWebView('onTerminalStatus', {
        'status': result,
        'ipAddress': ipAddress,
        'serialNumber': serialNumber,
        'instanceId': instanceId,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verifone: $result'),
            backgroundColor: result == 'CONNECTED' ? Colors.green : Colors.orange,
          ),
        );
      }

      return result;
    } on PlatformException catch (e) {
      debugPrint('Terminal configure error: ${e.message}');
      _sendToWebView('onTerminalStatus', {
        'status': 'ERROR',
        'code': e.code,
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

      return null;
    }
  }

  /// Reads the saved terminal configuration and reconnects automatically.
  ///
  /// Called after the web page finishes loading so that the
  /// `onTerminalStatus` JavaScript handler is ready to receive the response.
  Future<void> _autoConnectTerminal() async {
    final preferences =
        await SharedPreferences.getInstance();

    final ipAddress =
        preferences.getString('terminalIpAddress') ?? '';

    final serialNumber =
        preferences.getString('terminalSerialNumber') ?? '';

    final instanceId =
        preferences.getString('terminalInstanceId') ?? '';

    final posDeviceId =
        preferences.getString('terminalPosDeviceId') ?? '';

    if (ipAddress.isEmpty ||
        serialNumber.isEmpty ||
        instanceId.isEmpty ||
        posDeviceId.isEmpty) {
      _sendToWebView('onTerminalStatus', {
        'status': 'NOT_CONFIGURED',
      });
      return;
    }

    _sendToWebView('onTerminalStatus', {
      'status': 'CONNECTING',
    });

    final String? result = await _configureTerminal({
      'payload': {
        'ipAddress': ipAddress,
        'serialNumber': serialNumber,
        'instanceId': instanceId,
        'posDeviceId': posDeviceId,
      }
    });

    if (result != 'CONNECTED') {
      final preferences =
          await SharedPreferences.getInstance();

      await preferences.remove('terminalIpAddress');
      await preferences.remove('terminalSerialNumber');
      await preferences.remove('terminalInstanceId');
      await preferences.remove('terminalPosDeviceId');

      _terminalIpAddress = '';

      _sendToWebView('onTerminalStatus', {
        'status': 'NOT_CONFIGURED',
      });
    }
  }

  /// Forgets the saved terminal, removes its persisted configuration,
  /// and tells the web page to show the setup popup again.
  Future<void> _changeTerminal() async {
    try {
      final String result =
          await platform.invokeMethod('forgetTerminal');

      final preferences =
          await SharedPreferences.getInstance();

      await preferences.remove('terminalIpAddress');
      await preferences.remove('terminalSerialNumber');
      await preferences.remove('terminalInstanceId');
      await preferences.remove('terminalPosDeviceId');

      _terminalIpAddress = '';

      _sendToWebView('onTerminalStatus', {
        'status': 'NOT_CONFIGURED',
        'result': result,
      });
    } on PlatformException catch (e) {
      _sendToWebView('onTerminalStatus', {
        'status': 'ERROR',
        'code': e.code,
        'message': e.message,
      });
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
  // PRINTER LOGIC (USB only)
  // ================================================================

  void _printBill(Map<String, dynamic> data) async {
    try {
      // Extract the actual receipt data from the NativeBridge message wrapper.
      // The frontend sends: { type: "PRINT", payload: { order: {...}, vendor: {...} } }
      final Map<String, dynamic> receiptData =
          data['payload'] as Map<String, dynamic>? ?? data;

      // Determine whether the cash drawer should be opened.
      final Map<String, dynamic> order =
          receiptData['order'] as Map<String, dynamic>? ?? {};
      final bool isCopy = order['isCopy'] == true;
      final String paymentMethod =
          order['paymentMethod']?.toString().trim().toLowerCase() ?? '';
      final bool shouldOpenDrawer =
          !isCopy && (paymentMethod == 'cash' || paymentMethod == 'kontant');

      // Ensure USB printer is connected (auto-reconnect if needed).
      final bool usbReady = await _usbPrinterService.ensureConnected();

      if (!usbReady) {
        _sendToWebView('onPrintResult', {
          'success': false,
          'error': 'USB printer not connected or not found',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('USB printer not connected or not found'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Send receipt and optional drawer command to the USB printer.
      final bool success = await _usbPrinterService.printBill(
        receiptData,
        openDrawer: shouldOpenDrawer,
      );

      if (success) {
        _sendToWebView('onPrintResult', {
          'success': true,
          'drawerCommandSent': shouldOpenDrawer,
        });
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