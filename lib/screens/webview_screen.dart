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
    _loadSavedIpAndConnect();

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
              case 'CHECK_TERMINAL':
                _checkVerifoneStatus();
                break;
              case 'CHECK_PRINTER':
                _checkPrinterStatus();
                break;
              case 'PAYMENT':
                _startPayment(data);
                break;
              case 'PRINT':
                _printBill(data);
                break;
              case 'END_SESSION':
                _endSession();
                break;
              case 'SHOW_CONFIG':
                _showManualIpDialog();
                break;
              case 'DISCONNECT':
                _disconnectTerminal();
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
            // Inject terminal config if available
            _injectTerminalConfig();
            // Inject Test Payment Button
            // _injectTestPaymentButton();
          },
        ),
      )
      ..loadRequest(
        Uri.parse('https://betalia.no/bakeri/cashier/login'),
      );
  }

  // ================================================================
  // TERMINAL CONFIGURATION
  // ================================================================

  /// Injects a floating "TEST PAY 5 NOK" button for standalone payment testing.
  void _injectTestPaymentButton() {
    final js = '''
(function() {
  if (document.getElementById('__verifone_test_btn')) return;
  var btn = document.createElement('button');
  btn.id = '__verifone_test_btn';
  btn.innerText = 'TEST PAY 5 NOK';
  btn.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:99999;' +
    'padding:14px 24px;background:#4CAF50;color:white;border:none;' +
    'border-radius:12px;font-size:16px;font-weight:bold;' +
    'box-shadow:0 4px 12px rgba(0,0,0,0.3);cursor:pointer;';
  btn.onclick = function() {
    try {
      NativeBridge.postMessage(JSON.stringify({
        type: 'PAYMENT',
        payload: { amount: 5, currency: 'NOK' }
      }));
      btn.innerText = 'PROCESSING...';
      btn.style.background = '#FF9800';
      setTimeout(function() { btn.innerText = 'TEST PAY 5 NOK'; btn.style.background = '#4CAF50'; }, 5000);
    } catch(e) {
      alert('Error: ' + e.message);
    }
  };
  document.body.appendChild(btn);
})();
''';
    controller.runJavaScript(js);
  }

  /// Injects stored terminal IP config into the WebView so the frontend
  /// knows where to connect.
  void _injectTerminalConfig() {
    if (_terminalIpAddress.isNotEmpty) {
      controller.runJavaScript(
        'if(window.onTerminalConfig) window.onTerminalConfig('
        '${jsonEncode({"ipAddress": _terminalIpAddress, "port": _terminalPort})}'
        ')',
      );
    }
  }

  /// Loads saved terminal IP and auto-connects. Falls back to hardcoded test IP.
  Future<void> _loadSavedIpAndConnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('verifone_terminal_ip');
      final savedPort = prefs.getString('verifone_terminal_port');

      String ipToUse;
      String portToUse;

      // Hardcoded client P630 IP for testing
      ipToUse = '192.168.86.55';
      portToUse = '';

      _terminalIpAddress = ipToUse;
      _terminalPort = portToUse;
      debugPrint('Connecting to terminal: $ipToUse');

      final String result = await platform.invokeMethod('configureTerminal', {
        'ipAddress': ipToUse,
        'port': portToUse,
      });

      debugPrint('Connect result: $result');
      final connected = result == 'CONNECTED';

      // Update the test button to reflect connection state
      _updateTestButtonState(connected, ipToUse);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(connected
                ? 'Verifone connected: $ipToUse'
                : 'Verifone: $result'),
            backgroundColor: connected ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error connecting to terminal: $e');
      _updateTestButtonState(false, e.toString());
      if (mounted) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   SnackBar(
        //     content: Text('Connection error: $e'),
        //     backgroundColor: Colors.red,
        //     duration: const Duration(seconds: 4),
        //   ),
        // );
      }
    }
  }

  /// Updates the injected TEST PAY button with connection state.
  void _updateTestButtonState(bool connected, String message) {
    final color = connected ? '#4CAF50' : '#F44336';
    final text = connected ? 'TEST PAY 5 NOK' : 'CONN FAILED - Tap Retry';
    final title = connected ? 'TEST PAY 5 NOK' : 'CONN FAILED - Tap Retry';
    final js = '''
(function() {
  var btn = document.getElementById('__verifone_test_btn');
  if (!btn) return;
  btn.innerText = '$title';
  btn.style.background = '$color';
})();
''';
    controller.runJavaScript(js);
  }

  /// Saves the terminal IP to SharedPreferences for future auto-connect.
  Future<void> _saveTerminalIp(String ip, String port) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('verifone_terminal_ip', ip);
      if (port.isNotEmpty) {
        await prefs.setString('verifone_terminal_port', port);
      }
    } catch (e) {
      debugPrint('Error saving terminal IP: $e');
    }
  }

  /// Shows a picker dialog when multiple terminals are discovered.
  Future<String?> _showTerminalPickerDialog(List<dynamic> devices) async {
    final selectedIp = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Terminal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Found ${devices.length} Verifone terminals on the network:',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            ...devices.map((device) {
              final ip = device is Map ? device['ipAddress']?.toString() ?? '' : device.toString();
              return ListTile(
                leading: const Icon(Icons.credit_card, color: Colors.green),
                title: Text('Terminal at $ip'),
                subtitle: const Text('P630'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                onTap: () => Navigator.pop(ctx, ip),
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Enter IP manually'),
          ),
        ],
      ),
    );
    return selectedIp;
  }

  /// Shows a dialog for manual IP entry.
  Future<void> _showManualIpDialog() async {
    final ipController = TextEditingController(text: _terminalIpAddress);
    final portController = TextEditingController(text: _terminalPort);

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Configure Terminal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the P630 terminal IP address:',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'IP Address',
                hintText: '192.168.1.100',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portController,
              decoration: const InputDecoration(
                labelText: 'Port (optional)',
                hintText: '16101',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx, {
                'ip': ipController.text.trim(),
                'port': portController.text.trim(),
              });
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );

    if (result != null && result['ip']!.isNotEmpty) {
      final ip = result['ip']!;
      final port = result['port'] ?? '';
      _terminalIpAddress = ip;
      _terminalPort = port;
      await _saveTerminalIp(ip, port);
      _configureTerminal({'ipAddress': ip, 'port': port});
    }
  }

  /// Configures the Verifone P630 terminal IP and initializes the connection.
  void _configureTerminal(Map<String, dynamic> data) async {
    final ip = (data['payload']?['ipAddress'] ?? data['ipAddress'] ?? '').toString();
    final port = (data['payload']?['port'] ?? data['port'] ?? '').toString();

    // If no IP provided, try auto-discovery on the native side
    if (ip.isEmpty) {
      debugPrint('CONFIGURE_TERMINAL: No IP provided — attempting auto-discovery');
      try {
        final String result = await platform.invokeMethod('configureTerminal', {
          'ipAddress': '',
          'port': '',
        });

        final parsed = jsonDecode(result);
        if (parsed['status'] == 'MULTIPLE_FOUND') {
          // Multiple terminals found — show picker dialog
          final devices = parsed['devices'] as List<dynamic>? ?? [];
          final selectedIp = await _showTerminalPickerDialog(devices);
          if (selectedIp != null) {
            // User selected a terminal — configure with that IP
            _configureTerminal({'ipAddress': selectedIp, 'port': ''});
          } else {
            _sendToWebView('onTerminalStatus', parsed);
          }
          return;
        }
        if (parsed['status'] == 'NOT_FOUND') {
          // No terminal found — show manual IP dialog
          _sendToWebView('onTerminalStatus', parsed);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(parsed['message'] ?? 'No terminal found'),
                backgroundColor: Colors.red,
                action: SnackBarAction(
                  label: 'Enter IP',
                  textColor: Colors.white,
                  onPressed: _showManualIpDialog,
                ),
                duration: const Duration(seconds: 8),
              ),
            );
          }
          return;
        }
        // If discovered or connected, save the IP
        if (parsed['ipAddress'] != null) {
          _terminalIpAddress = parsed['ipAddress'];
          await _saveTerminalIp(_terminalIpAddress, _terminalPort);
        }
        _sendToWebView('onTerminalStatus', parsed);
      } on PlatformException catch (e) {
        _sendToWebView('onTerminalStatus', {'status': 'ERROR', 'message': e.message});
      }
      return;
    }

    _terminalIpAddress = ip;
    _terminalPort = port;
    await _saveTerminalIp(ip, port);

    try {
      final String result = await platform.invokeMethod('configureTerminal', {
        'ipAddress': ip,
        'port': port,
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
        _updateTestButtonState(false, 'NOT_CONNECTED');
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
  // TERMINAL STATUS CHECK
  // ================================================================

  void _checkVerifoneStatus() async {
    try {
      final String resultJson = await platform.invokeMethod('checkTerminalStatus');
      final result = jsonDecode(resultJson);

      _sendToWebView('onTerminalStatus', result);

      if (mounted) {
        final status = result['status'] ?? 'UNKNOWN';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verifone: $status'),
            backgroundColor: status == 'CONNECTED' ? Colors.green : Colors.grey,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } on PlatformException catch (e) {
      debugPrint('Status check error: ${e.message}');
      _sendToWebView('onTerminalStatus', {'status': 'ERROR', 'message': e.message});
    }
  }

  // ================================================================
  // SESSION MANAGEMENT
  // ================================================================

  void _endSession() async {
    try {
      await platform.invokeMethod('endSession');
      debugPrint('Session ended');
    } catch (e) {
      debugPrint('End session error: $e');
    }
  }

  void _disconnectTerminal() async {
    try {
      await platform.invokeMethod('disconnect');
      _terminalIpAddress = '';
      _terminalPort = '';
      debugPrint('Terminal disconnected');
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }

  // ================================================================
  // PRINTER LOGIC
  // ================================================================

  void _checkPrinterStatus() {
    final isConnected = _printerService.isConnected || _usbPrinterService.isConnected;
    _sendToWebView('onPrinterStatus', {'connected': isConnected});
  }

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