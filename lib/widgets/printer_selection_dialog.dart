import 'package:flutter/material.dart';
import '../services/usb_printer_service.dart';
import '../services/ethernet_printer_service.dart';

class PrinterSelectionDialog extends StatefulWidget {
  const PrinterSelectionDialog({super.key});

  @override
  State<PrinterSelectionDialog> createState() => _PrinterSelectionDialogState();
}

class _PrinterSelectionDialogState extends State<PrinterSelectionDialog>
    with SingleTickerProviderStateMixin {
  final UsbPrinterService _usbPrinterService = UsbPrinterService();
  final EthernetPrinterService _ethernetPrinterService =
      EthernetPrinterService();

  late final TabController _tabController;

  // USB tab state (unchanged)
  List<Map<String, dynamic>> _usbDevices = [];
  bool _usbLoading = true;

  // Ethernet tab state
  List<Map<String, dynamic>> _ethernetDevices = [];
  bool _ethernetLoading = false;
  bool _ethernetScanned = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _getUsbDevices();
    // Auto-scan Ethernet on tab open.
    _tabController.addListener(() {
      if (_tabController.index == 1 && !_ethernetScanned && !_ethernetLoading) {
        _scanEthernet();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // USB tab (unchanged from original)
  // ---------------------------------------------------------------------------

  Future<void> _getUsbDevices() async {
    setState(() => _usbLoading = true);
    final devices = await _usbPrinterService.getUsbDevices();
    if (mounted) {
      setState(() {
        _usbDevices = devices;
        _usbLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Ethernet tab
  // ---------------------------------------------------------------------------

  Future<void> _scanEthernet() async {
    setState(() {
      _ethernetLoading = true;
      _ethernetScanned = true;
    });
    final devices = await _ethernetPrinterService.scanNetwork();
    if (mounted) {
      setState(() {
        _ethernetDevices = devices;
        _ethernetLoading = false;
      });
    }
  }

  Future<void> _connectEthernet(
    String ip,
    int port,
    String? existingName,
  ) async {
    // If no saved name, prompt the user first.
    String? printerName = existingName;

    if (printerName == null) {
      printerName = await showDialog<String>(
        context: context,
        builder: (ctx) => _NamePromptDialog(ip: ip),
      );
      if (printerName == null || printerName.trim().isEmpty) {
        return; // user cancelled or entered empty name
      }
      printerName = printerName.trim();
      await _ethernetPrinterService.savePrinterName(ip, printerName);
    }

    if (!mounted) return;

    final success = await _ethernetPrinterService.connectToPrinter(ip, port: port);

    if (mounted) {
      if (success) {
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to connect to Ethernet printer'),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Printer'),
      content: SizedBox(
        width: double.maxFinite,
        height: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'USB Printers'),
                Tab(text: 'Wifi/Ethernet Printers'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // ============================================================
                  // USB PRINTER TAB (unchanged from original)
                  // ============================================================
                  _usbLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _usbDevices.isEmpty
                          ? const Center(
                              child: Text(
                                'No USB devices found.\nPlease connect your printer.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : Column(
                              children: [
                                Expanded(
                                  child: ListView.builder(
                                    itemCount: _usbDevices.length,
                                    itemBuilder: (context, index) {
                                      final device = _usbDevices[index];
                                      return ListTile(
                                        leading: const Icon(Icons.usb),
                                        title: Text(
                                          device['productName'] ??
                                              device['deviceName'] ??
                                              'Unknown USB Device',
                                        ),
                                        subtitle: Text(
                                          'VID: ${device['vendorId']} PID: ${device['productId']}',
                                        ),
                                        onTap: () async {
                                          final success =
                                              await _usbPrinterService
                                                  .connectToDevice(device);
                                          if (mounted) {
                                            if (success) {
                                              Navigator.pop(context, true);
                                            } else {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Failed to connect USB',
                                                  ),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                      );
                                    },
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4.0, bottom: 4.0),
                                  child: TextButton.icon(
                                    onPressed: _getUsbDevices,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Rescan USB'),
                                  ),
                                ),
                              ],
                            ),

                  // ============================================================
                  // ETHERNET PRINTER TAB
                  // ============================================================
                  _ethernetLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _ethernetDevices.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'No Ethernet printers found on port 9100.\nTap Scan to search your network.',
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  ElevatedButton.icon(
                                    onPressed: _scanEthernet,
                                    icon: const Icon(Icons.search),
                                    label: const Text('Scan Network'),
                                  ),
                                ],
                              ),
                            )
                          : Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4.0,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Found ${_ethernetDevices.length} device(s)',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      TextButton.icon(
                                        onPressed: _scanEthernet,
                                        icon: const Icon(
                                          Icons.refresh,
                                          size: 18,
                                        ),
                                        label: const Text('Rescan'),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    itemCount: _ethernetDevices.length,
                                    itemBuilder: (context, index) {
                                      final device = _ethernetDevices[index];
                                      final String ip =
                                          device['ip'] as String;
                                      final int port =
                                          device['port'] as int;
                                      final String? name =
                                          device['name'] as String?;

                                      return ListTile(
                                        leading: Icon(
                                          name != null
                                              ? Icons.print
                                              : Icons.lan,
                                        ),
                                        title: Text(
                                          name ?? ip,
                                        ),
                                        subtitle: Text('$ip:$port'),
                                        trailing: name != null
                                            ? null
                                            : const Icon(
                                                Icons.edit,
                                                size: 18,
                                              ),
                                        onTap: () => _connectEthernet(
                                          ip,
                                          port,
                                          name,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// =============================================================================
// Name prompt sub-dialog shown when an Ethernet printer has no saved name.
// =============================================================================

class _NamePromptDialog extends StatefulWidget {
  final String ip;
  const _NamePromptDialog({required this.ip});

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name this printer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Give this printer a name:'),
          const SizedBox(height: 4),
          Text(
            widget.ip,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'e.g. Kitchen Printer',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                Navigator.pop(context, value.trim());
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isNotEmpty) {
              Navigator.pop(context, name);
            }
          },
          child: const Text('Save & Connect'),
        ),
      ],
    );
  }
}