import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/printer_text_utils.dart';

class EthernetPrinterService extends ChangeNotifier {
  static final EthernetPrinterService _instance =
      EthernetPrinterService._internal();
  factory EthernetPrinterService() => _instance;
  EthernetPrinterService._internal();

  bool _isConnected = false;
  bool _isConnecting = false;
  Socket? _socket;
  Map<String, dynamic>? _connectedDevice;

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectedDeviceName =>
      _connectedDevice?['name'] ?? _connectedDevice?['ip'];

  // SharedPreferences keys
  static const String _prefLastIpKey = 'ethernet_printer_last_ip';
  static const String _prefPrinterNamesKey = 'ethernet_printer_names';

  /// USB chunk size for print writes (4 KB).
  static const int _tcpChunkSize = 4096;

  // ---------------------------------------------------------------------------
  // Network scan for port 9100 devices
  // ---------------------------------------------------------------------------

  /// Scans the local subnet for devices with port 9100 open.
  ///
  /// Returns a list of [Map]s with keys:
  ///   - `ip` (String): the IP address
  ///   - `port` (int): always 9100
  ///   - `name` (String?): user-assigned name if saved, null otherwise
  Future<List<Map<String, dynamic>>> scanNetwork() async {
    // Load previously saved names.
    final Map<String, String> savedNames = await _loadPrinterNames();

    // Determine the local subnet prefix.
    final String? subnetPrefix = await _getLocalSubnetPrefix();
    if (subnetPrefix == null) {
      debugPrint('EthernetPrinterService: could not determine local subnet');
      return [];
    }

    final List<Map<String, dynamic>> found = [];
    const int port = 9100;
    const int timeoutMs = 500;

    // Probe all 254 addresses concurrently in batches of 50.
    final List<Future<void>> futures = [];
    for (int host = 1; host <= 254; host++) {
      final String ip = '$subnetPrefix.$host';
      futures.add(
        _probeHost(ip, port, timeoutMs).then((reachable) {
          if (reachable) {
            found.add({
              'ip': ip,
              'port': port,
              'name': savedNames[ip],
            });
          }
        }),
      );
      // Batch every 50 to avoid overwhelming the network stack.
      if (futures.length >= 50) {
        await Future.wait(futures);
        futures.clear();
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }

    // Sort by IP (last octet ascending).
    found.sort((a, b) {
      final aIp = a['ip'] as String;
      final bIp = b['ip'] as String;
      final int aLast = int.tryParse(aIp.split('.').last) ?? 0;
      final int bLast = int.tryParse(bIp.split('.').last) ?? 0;
      return aLast.compareTo(bLast);
    });

    debugPrint(
      'EthernetPrinterService: scan found ${found.length} device(s) on port 9100',
    );
    return found;
  }

  /// Tries to open a TCP socket to [ip]:[port] with [timeoutMs] timeout.
  /// Returns `true` if the connection succeeds, indicating the port is open.
  Future<bool> _probeHost(String ip, int port, int timeoutMs) async {
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: Duration(milliseconds: timeoutMs),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the local IPv4 subnet prefix (e.g., "192.168.1") by inspecting
  /// the device's network interfaces.
  Future<String?> _getLocalSubnetPrefix() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
            final parts = address.address.split('.');
            if (parts.length == 4) {
              return '${parts[0]}.${parts[1]}.${parts[2]}';
            }
          }
        }
      }
    } catch (e) {
      debugPrint('EthernetPrinterService: error listing interfaces: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Name persistence (IP → user-assigned name)
  // ---------------------------------------------------------------------------

  Future<Map<String, String>> _loadPrinterNames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? json = prefs.getString(_prefPrinterNamesKey);
      if (json == null || json.isEmpty) return {};
      return _tryDecode(json);
    } catch (e) {
      debugPrint('EthernetPrinterService: error loading printer names: $e');
      return {};
    }
  }

  Future<void> _savePrinterNames(Map<String, String> names) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String json = _mapToJson(names);
      await prefs.setString(_prefPrinterNamesKey, json);
    } catch (e) {
      debugPrint('EthernetPrinterService: error saving printer names: $e');
    }
  }

  /// Saves a user-assigned name for the given Ethernet printer IP.
  Future<void> savePrinterName(String ip, String name) async {
    final Map<String, String> names = await _loadPrinterNames();
    names[ip] = name;
    await _savePrinterNames(names);
    debugPrint('EthernetPrinterService: saved name "$name" for $ip');
  }

  Map<String, String> _tryDecode(String json) {
    try {
      final map = <String, String>{};
      if (json.startsWith('{') && json.endsWith('}')) {
        final inner = json.substring(1, json.length - 1);
        if (inner.trim().isEmpty) return map;
        final regex = RegExp(
          r'''"([^"\\]*(?:\\.[^"\\]*)*)"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"''',
        );
        for (final match in regex.allMatches(inner)) {
          map[match.group(1)!] = match.group(2)!;
        }
      }
      return map;
    } catch (_) {
      return <String, String>{};
    }
  }

  String _mapToJson(Map<String, String> map) {
    final buffer = StringBuffer('{');
    bool first = true;
    for (final entry in map.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('"${entry.key}":"${entry.value}"');
    }
    buffer.write('}');
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // Automatic connection (ensureConnected)
  // ---------------------------------------------------------------------------

  /// Tries to auto-connect to the last-used Ethernet printer.
  ///
  /// * Returns `true` immediately if already connected.
  /// * If a connection is in progress, waits for it to finish (up to 15s).
  /// * Only tries the persisted IP — no blind fallback.
  /// * Returns `false` when no saved printer is found or it's unreachable.
  Future<bool> ensureConnected() async {
    if (_isConnected) {
      debugPrint('EthernetPrinterService: already connected');
      return true;
    }

    if (_isConnecting) {
      debugPrint('EthernetPrinterService: connection in progress, waiting...');
      int waitedMs = 0;
      while (_isConnecting && waitedMs < 15000) {
        await Future.delayed(const Duration(milliseconds: 300));
        waitedMs += 300;
      }
      if (_isConnected) {
        debugPrint('EthernetPrinterService: connected after waiting');
        return true;
      }
      if (_isConnecting) {
        debugPrint('EthernetPrinterService: timed out waiting for connection');
        return false;
      }
    }

    _isConnecting = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final String? savedIp = prefs.getString(_prefLastIpKey);

      if (savedIp == null || savedIp.isEmpty) {
        debugPrint('EthernetPrinterService: no saved printer IP');
        return false;
      }

      debugPrint(
        'EthernetPrinterService: connecting to saved printer $savedIp:9100',
      );

      final bool success = await _connectToIp(savedIp, 9100);

      if (success) {
        // Check if we have a saved name.
        final names = await _loadPrinterNames();
        _connectedDevice = {
          'ip': savedIp,
          'port': 9100,
          'name': names[savedIp],
        };
        debugPrint(
          'EthernetPrinterService: auto-connected to ${names[savedIp] ?? savedIp}',
        );
        notifyListeners();
        return true;
      }

      debugPrint(
        'EthernetPrinterService: saved printer $savedIp not reachable',
      );
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('EthernetPrinterService: ensureConnected error: $e');
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Manual connection
  // ---------------------------------------------------------------------------

  /// Connects to the Ethernet printer at [ip] on [port] (default 9100).
  ///
  /// Persists the IP for future auto-connect.
  Future<bool> connectToPrinter(String ip, {int port = 9100}) async {
    _isConnecting = true;

    try {
      debugPrint('EthernetPrinterService: connecting to $ip:$port...');

      final bool success = await _connectToIp(ip, port);

      if (success) {
        _isConnected = true;

        // Load saved name if present.
        final names = await _loadPrinterNames();
        _connectedDevice = {
          'ip': ip,
          'port': port,
          'name': names[ip],
        };

        // Persist last IP for future auto-connect.
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefLastIpKey, ip);
          debugPrint('EthernetPrinterService: saved last IP $ip');
        } catch (e) {
          debugPrint('EthernetPrinterService: failed to save last IP: $e');
        }

        debugPrint(
          'EthernetPrinterService: connected to ${names[ip] ?? ip}:$port',
        );
        notifyListeners();
        return true;
      }

      debugPrint('EthernetPrinterService: connection failed to $ip:$port');
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('EthernetPrinterService: error connecting: $e');
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  Future<bool> _connectToIp(String ip, int port) async {
    try {
      _socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 5),
      );
      _socket?.setOption(SocketOption.tcpNoDelay, true);
      debugPrint('EthernetPrinterService: socket connected to $ip:$port');
      return true;
    } catch (e) {
      debugPrint('EthernetPrinterService: socket connect failed: $e');
      _socket = null;
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Disconnect
  // ---------------------------------------------------------------------------

  Future<void> disconnect() async {
    try {
      await _socket?.close();
      _socket = null;
      debugPrint('EthernetPrinterService: socket closed');
    } catch (e) {
      debugPrint('EthernetPrinterService: error closing socket: $e');
    } finally {
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Print receipt
  // ---------------------------------------------------------------------------

  /// Generates and sends the receipt to the connected Ethernet printer.
  ///
  /// When [openDrawer] is `true` the cash-drawer kick command is appended.
  Future<bool> printBill(
    Map<String, dynamic> data, {
    bool openDrawer = false,
  }) async {
    if (!_isConnected || _socket == null) {
      debugPrint('EthernetPrinterService: no Ethernet printer connected');
      return false;
    }

    final Map<String, dynamic> order =
        data['order'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final Map<String, dynamic> vendor =
        data['vendor'] as Map<String, dynamic>? ?? <String, dynamic>{};

    if (order.isEmpty && vendor.isEmpty) {
      debugPrint('EthernetPrinterService: receipt dataset payload is empty');
      return false;
    }

    try {
      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.mm80, profile);
      List<int> bytes = <int>[];

      // =====================================================================
      // 1. VENDOR HEADER BLOCK
      // =====================================================================
      final String vendorName = stripEmojis(vendor['name'] as String? ?? 'Restaurant');
      bytes += generator.text(
        vendorName,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      );

      if (vendor['address'] != null) {
        bytes += generator.text(
          stripEmojis(vendor['address'] as String),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['city'] != null) {
        final String zip = stripEmojis(vendor['zipCode'] as String? ?? '');
        bytes += generator.text(
          stripEmojis('${vendor['city']} $zip'.trim()),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['phone'] != null) {
        bytes += generator.text(
          stripEmojis('Tel: ${vendor['phone']}'),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (vendor['organizationId'] != null) {
        bytes += generator.text(
          stripEmojis('Org ID: ${vendor['organizationId']}'),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      bytes += generator.hr();

      // =====================================================================
      // 2. RECEIPT META TITLE BLOCK
      // =====================================================================
      final bool isCopy = order['isCopy'] == true;
      final String receiptLabel =
          isCopy ? 'KOPIKVITTERING' : 'SALGSKVITTERING';
      bytes += generator.text(
        stripEmojis(receiptLabel),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        stripEmojis('Receipt - ${order['orderNumber'] ?? ''}'),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      final String transactionIdStr =
          stripEmojis(order['transactionId']?.toString() ?? '');
      if (transactionIdStr.isNotEmpty) {
        bytes += generator.text(
          stripEmojis('Transaction ID: $transactionIdStr'),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      bytes += generator.hr();

      // =====================================================================
      // 3. ORDER DATA BLOCK (Key-Value Rows)
      // =====================================================================
      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Order Type:', width: 6),
        PosColumn(
          text: stripEmojis('${order['orderType'] ?? ''}'.toUpperCase()),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Payment:', width: 6),
        PosColumn(
          text: stripEmojis('${order['paymentMethod'] ?? ''}'.toUpperCase()),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Cashier :', width: 6),
        PosColumn(
          text: stripEmojis('${order['cashierName'] ?? '-'}'),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Terminal:', width: 6),
        PosColumn(
          text: stripEmojis('${order['deviceId'] ?? ''}'),
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      final List<dynamic> itemsList = order['items'] as List<dynamic>? ?? <dynamic>[];
      int totalItemCount = itemsList.fold<int>(0, (int sum, dynamic item) {
        return sum + ((item['quantity'] as num?)?.toInt() ?? 0);
      });

      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Total Items', width: 6),
        PosColumn(
          text: '$totalItemCount',
          width: 6,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      bytes += generator.hr();

      // =====================================================================
      // 4. ITEMS GRID HEADERS
      // =====================================================================
      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Item', width: 7, styles: const PosStyles(bold: true)),
        PosColumn(
          text: 'Qty',
          width: 2,
          styles: const PosStyles(align: PosAlign.center, bold: true),
        ),
        PosColumn(
          text: 'Price',
          width: 3,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      // =====================================================================
      // 5. PRINTING DYNAMIC ITEMS & SUBITEMS
      // =====================================================================
      for (dynamic itemDynamic in itemsList) {
        final Map<String, dynamic> item = itemDynamic as Map<String, dynamic>;

        double price = (item['price'] as num? ?? 0.0).toDouble();
        final int qty = (item['quantity'] as num? ?? 1).toInt();
        final double computedTotalPrice = price * qty;

        String itemName = '';
        if (item['menuItemId'] != null && item['menuItemId'] is Map) {
          final Map<dynamic, dynamic> menuItemField =
              item['menuItemId'] as Map<dynamic, dynamic>;
          itemName = stripEmojis(menuItemField['name']?.toString() ?? '');
        }

        bytes += generator.row(<PosColumn>[
          PosColumn(text: itemName, width: 7),
          PosColumn(
            text: '$qty',
            width: 2,
            styles: const PosStyles(align: PosAlign.center),
          ),
          PosColumn(
            text: computedTotalPrice.toStringAsFixed(2),
            width: 3,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);

        final List<dynamic>? selectedOptions = item['selectedOptions'] as List<dynamic>?;
        final List<dynamic>? subItems = item['subItems'] as List<dynamic>?;

        if (selectedOptions != null &&
            selectedOptions.isNotEmpty &&
            (subItems == null || subItems.isEmpty)) {
          for (dynamic og in selectedOptions) {
            final List<dynamic> choicesList = og['choices'] as List<dynamic>? ?? <dynamic>[];
            final String choicesStr =
                choicesList.map((dynamic c) => stripEmojis(c['name']?.toString() ?? '')).join(', ');
            bytes += generator.text(
              stripEmojis('  ${og['groupName']}: $choicesStr'),
              styles: const PosStyles(align: PosAlign.left),
            );
          }
        }

        if (subItems != null && subItems.isNotEmpty) {
          for (dynamic subDynamic in subItems) {
            final Map<String, dynamic> sub = subDynamic as Map<String, dynamic>;
            final int subQty = (sub['quantity'] as num? ?? 1).toInt();
            final String subPrefix = subQty > 1 ? '${subQty}x ' : '';

            bytes += generator.text(
              stripEmojis('  $subPrefix${sub['name'] ?? ''}'),
              styles: const PosStyles(align: PosAlign.left),
            );

            final List<dynamic>? subOpts = sub['selectedOptions'] as List<dynamic>?;
            if (subOpts != null && subOpts.isNotEmpty) {
              for (dynamic subOg in subOpts) {
                final List<dynamic> choicesList = subOg['choices'] as List<dynamic>? ?? <dynamic>[];
                final String choicesStr = choicesList
                    .map((dynamic c) => stripEmojis(c['name']?.toString() ?? ''))
                    .join(', ');
                bytes += generator.text(
                  stripEmojis('    ${subOg['groupName']}: $choicesStr'),
                  styles: const PosStyles(align: PosAlign.left),
                );
              }
            }
          }
        }
      }

      bytes += generator.hr();

      // =====================================================================
      // 6. GRAND TOTAL ROW
      // =====================================================================
      final double totalPrice =
          (order['totalPrice'] as num? ?? 0.0).toDouble();
      bytes += generator.row(<PosColumn>[
        PosColumn(
          text: 'TOTAL',
          width: 5,
          styles: const PosStyles(
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size1,
          ),
        ),
        PosColumn(
          text: 'kr ${totalPrice.toStringAsFixed(2)}',
          width: 7,
          styles: const PosStyles(
            align: PosAlign.right,
            bold: true,
            height: PosTextSize.size2,
            width: PosTextSize.size1,
          ),
        ),
      ]);

      bytes += generator.hr();

      // =====================================================================
      // 7. TAXES SUMMARY
      // =====================================================================
      final double subtotalPrice =
          (order['totalWithoutVat'] as num? ?? 0.0).toDouble();
      bytes += generator.row(<PosColumn>[
        PosColumn(text: 'Subtotal', width: 6),
        PosColumn(
          text: 'kr ${subtotalPrice.toStringAsFixed(2)}',
          width: 6,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      final double vatPrice = (order['vatPrice'] as num? ?? 0.0).toDouble();
      if (vatPrice > 0) {
        final Map<String, double> vatRates = <String, double>{
          'takeaway': 0.15,
          'dine': 0.25,
          'delivery': 0.15,
        };
        final double ratePercent =
            (vatRates[order['orderType']] ?? 0.15) * 100;

        bytes += generator.row(<PosColumn>[
          PosColumn(
            text: 'VAT (${ratePercent.toStringAsFixed(0)}%)',
            width: 6,
          ),
          PosColumn(
            text: 'kr ${vatPrice.toStringAsFixed(2)}',
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      bytes += generator.hr();

      // =====================================================================
      // 7b. CASH PAYMENT DETAILS
      // =====================================================================
      final String paymentMethodStr =
          order['paymentMethod']?.toString().toLowerCase() ?? '';
      final double cashReceived =
          (order['cashReceived'] as num? ?? 0.0).toDouble();
      final double cashChange =
          (order['cashChange'] as num? ?? 0.0).toDouble();

      if (paymentMethodStr == 'cash' && cashReceived > 0) {
        bytes += generator.row(<PosColumn>[
          PosColumn(text: 'Cash Received', width: 6),
          PosColumn(
            text: 'kr ${cashReceived.toStringAsFixed(2)}',
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
        bytes += generator.row(<PosColumn>[
          PosColumn(text: 'Change', width: 6),
          PosColumn(
            text: 'kr ${cashChange.toStringAsFixed(2)}',
            width: 6,
            styles: const PosStyles(
              align: PosAlign.right,
              bold: true,
            ),
          ),
        ]);
        bytes += generator.hr();
      }

      // =====================================================================
      // 7c. CARD TRANSACTION DETAILS (AID, TVR, TSI, REF)
      // =====================================================================
      final Map<String, dynamic>? transaction =
          order['transaction'] as Map<String, dynamic>?;

      if (paymentMethodStr == 'card' && transaction != null) {
        final String? aid = transaction['aid']?.toString();
        final String? tvr = transaction['tvr']?.toString();
        final String? tsi = transaction['tsi']?.toString();
        final String? ref = transaction['ref']?.toString();
        final String? authResult = transaction['authResult']?.toString();

        if (aid != null && aid.isNotEmpty) {
          bytes += generator.row(<PosColumn>[
            PosColumn(text: 'AID', width: 4),
            PosColumn(
              text: stripEmojis(aid),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (tvr != null && tvr.isNotEmpty) {
          bytes += generator.row(<PosColumn>[
            PosColumn(text: 'TVR', width: 4),
            PosColumn(
              text: stripEmojis(tvr),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (tsi != null && tsi.isNotEmpty) {
          bytes += generator.row(<PosColumn>[
            PosColumn(text: 'TSI', width: 4),
            PosColumn(
              text: stripEmojis(tsi),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (ref != null && ref.isNotEmpty) {
          bytes += generator.row(<PosColumn>[
            PosColumn(text: 'REF', width: 4),
            PosColumn(
              text: stripEmojis(ref),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        if (authResult != null && authResult.isNotEmpty) {
          bytes += generator.row(<PosColumn>[
            PosColumn(text: 'Auth', width: 4),
            PosColumn(
              text: stripEmojis(authResult),
              width: 8,
              styles: const PosStyles(align: PosAlign.right),
            ),
          ]);
        }
        bytes += generator.hr();
      }

      // =====================================================================
      // 8. FOOTER / BRANDING BLOCK
      // =====================================================================
      final Map<String, dynamic> vendorOthers =
          vendor['others'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final String receiptMessage =
          vendorOthers['receiptMessage'] as String? ?? 'Takk for deres besøk!';

      bytes += generator.text(
        stripEmojis(receiptMessage),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        stripEmojis(vendorName),
        styles: const PosStyles(align: PosAlign.center),
      );

      final String createdAtStr =
          order['createdAt']?.toString() ?? DateTime.now().toIso8601String();
      try {
        final DateTime dt = DateTime.parse(createdAtStr);
        const List<String> months = <String>[
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        final String formattedDate =
            '${dt.day.toString().padLeft(2, '0')} '
            '${months[dt.month - 1]} ${dt.year} '
            'at ${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}';
        bytes += generator.text(
          formattedDate,
          styles: const PosStyles(align: PosAlign.center),
        );
      } catch (_) {
        bytes += generator.text(
          stripEmojis(createdAtStr),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      if (vendor['website'] != null &&
          (vendor['website'] as String).trim().isNotEmpty) {
        bytes += generator.text(
          stripEmojis(vendor['website'] as String),
          styles: const PosStyles(align: PosAlign.center),
        );
      }

      // =====================================================================
      // 9. PAPER FEED, OPTIONAL CASH DRAWER, CUT
      // =====================================================================
      bytes += generator.feed(3);

      if (openDrawer) {
        bytes += generator.drawer(pin: PosDrawer.pin2);
        debugPrint('EthernetPrinterService: cash drawer command appended');
      }

      bytes += generator.cut();

      // =====================================================================
      // 10. CHUNKED TCP WRITE – AVOID PRINTER BUFFER OVERFLOW
      // =====================================================================
      const int chunkSize = _tcpChunkSize;

      debugPrint(
        'EthernetPrinterService: sending ${bytes.length} bytes in '
        '${(bytes.length / chunkSize).ceil()} chunk(s) to Ethernet printer '
        '(drawer: $openDrawer)',
      );

      try {
        for (int offset = 0; offset < bytes.length; offset += chunkSize) {
          final int end = (offset + chunkSize > bytes.length)
              ? bytes.length
              : offset + chunkSize;
          final List<int> chunk = bytes.sublist(offset, end);

          _socket!.add(Uint8List.fromList(chunk));
          await _socket!.flush();

          if (end < bytes.length) {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }
      } catch (e) {
        debugPrint('EthernetPrinterService: TCP write threw exception: $e');
        _resetConnectionState();
        return false;
      }

      debugPrint('EthernetPrinterService: receipt sent successfully');
      return true;
    } catch (e) {
      debugPrint('EthernetPrinterService: error printing Ethernet bill: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _resetConnectionState() {
    _isConnected = false;
    _connectedDevice = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    notifyListeners();
    debugPrint(
      'EthernetPrinterService: connection state reset after write failure',
    );
  }
}