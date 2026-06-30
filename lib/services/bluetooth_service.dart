import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

class AppBluetoothService {
  fbp.BluetoothDevice? _connectedDevice;
  fbp.BluetoothDevice? get connectedDevice => _connectedDevice;

  Stream<List<fbp.ScanResult>> get scanResults => fbp.FlutterBluePlus.scanResults;
  Stream<bool> get isScanning => fbp.FlutterBluePlus.isScanning;

  Future<void> startScan() async {
    await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
  }

  Future<void> stopScan() async {
    await fbp.FlutterBluePlus.stopScan();
  }

  Future<void> connect(fbp.BluetoothDevice device) async {
    await device.connect();
    _connectedDevice = device;
  }

  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
  }
}

