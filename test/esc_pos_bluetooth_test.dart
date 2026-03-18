import 'dart:async';

import 'package:esc_pos_bluetooth/src/enums.dart';
import 'package:esc_pos_bluetooth/src/printer_bluetooth_manager.dart';
import 'package:flutter_bluetooth_basic/flutter_bluetooth_basic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

class FakePrinterBluetoothBackend implements PrinterBluetoothBackend {
  FakePrinterBluetoothBackend({
    this.failWritesOnChunkSizes = const <int>{},
    this.failWritesUntilConnectCount = 0,
    this.writeGate,
  });

  final BehaviorSubject<bool> _isScanning = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<List<BluetoothDevice>> _scanResults =
      BehaviorSubject<List<BluetoothDevice>>.seeded(<BluetoothDevice>[]);
  final BehaviorSubject<int?> _state =
      BehaviorSubject<int?>.seeded(BluetoothManager.DISCONNECTED);

  final Set<int> failWritesOnChunkSizes;
  final int failWritesUntilConnectCount;
  final Completer<void>? writeGate;

  final List<String> log = <String>[];
  final List<int> writeSizes = <int>[];
  int connectCount = 0;
  int disconnectCount = 0;
  int writeCount = 0;

  @override
  Stream<bool> get isScanningStream => _isScanning.stream;

  @override
  Stream<List<BluetoothDevice>> get scanResults => _scanResults.stream;

  @override
  Stream<int?> get state => _state.stream;

  void emitScanResults(List<BluetoothDevice> devices) {
    _scanResults.add(devices);
  }

  @override
  Future<void> connect(BluetoothDevice device) async {
    connectCount++;
    log.add('connect:${device.address}');
    _state.add(BluetoothManager.CONNECTED);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    log.add('disconnect');
    _state.add(BluetoothManager.DISCONNECTED);
  }

  @override
  Future<void> startScan(Duration timeout) async {
    log.add('startScan:${timeout.inMilliseconds}');
    _isScanning.add(true);
  }

  @override
  Future<void> stopScan() async {
    log.add('stopScan');
    _isScanning.add(false);
  }

  @override
  Future<void> writeData(List<int> bytes) async {
    writeCount++;
    writeSizes.add(bytes.length);
    log.add('write:${bytes.length}');

    if (writeGate != null && !writeGate!.isCompleted) {
      await writeGate!.future;
    }

    if (connectCount <= failWritesUntilConnectCount) {
      throw Exception('forced write failure for retry test');
    }

    if (failWritesOnChunkSizes.contains(bytes.length)) {
      throw Exception('forced write failure for chunk fallback test');
    }
  }

  Future<void> dispose() async {
    await _isScanning.close();
    await _scanResults.close();
    await _state.close();
  }
}

BluetoothDevice _device(String address, String name) {
  final device = BluetoothDevice();
  device.address = address;
  device.name = name;
  device.type = 1;
  return device;
}

void main() {
  test('startScan deduplicates devices by address', () async {
    final backend = FakePrinterBluetoothBackend();
    final manager = PrinterBluetoothManager(backend: backend);
    final emissions = <List<PrinterBluetooth>>[];
    final sub = manager.scanResults.listen(emissions.add);

    addTearDown(() async {
      await sub.cancel();
      await manager.dispose();
      await backend.dispose();
    });

    await Future<void>.delayed(Duration.zero);
    manager.startScan(const Duration(milliseconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    backend.emitScanResults(<BluetoothDevice>[
      _device('AA:11', 'Printer 1'),
      _device('AA:11', 'Printer 1 duplicate'),
      _device('BB:22', 'Printer 2'),
    ]);

    await Future<void>.delayed(Duration.zero);

    expect(emissions.isNotEmpty, isTrue);
    expect(
      emissions.last.map((printer) => printer.address).toList(),
      <String>['AA:11', 'BB:22'],
    );
  });

  test('printTicket queues jobs serially', () async {
    final gate = Completer<void>();
    final backend = FakePrinterBluetoothBackend(writeGate: gate);
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final first = manager.printTicket(List<int>.filled(8, 1));
    final second = manager.printTicket(List<int>.filled(4, 2));

    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(backend.connectCount, 1);
    expect(backend.writeCount, 1);

    gate.complete();

    expect(await first, PosPrintResult.success);
    expect(await second, PosPrintResult.success);

    expect(
      backend.log,
      <String>[
        'stopScan',
        'connect:AA:11',
        'write:8',
        'disconnect',
        'stopScan',
        'connect:AA:11',
        'write:4',
        'disconnect',
      ],
    );
  });

  test('printTicket falls back to smaller chunks when a write fails', () async {
    final backend = FakePrinterBluetoothBackend(failWritesOnChunkSizes: <int>{256});
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final result = await manager.printTicket(List<int>.filled(300, 7));

    expect(result, PosPrintResult.success);
    expect(backend.connectCount, 2);
    expect(backend.writeSizes, <int>[256, 128, 128, 44]);
  });

  test('printTicket retries the full job with backoff after repeated failures', () async {
    final backend = FakePrinterBluetoothBackend(failWritesUntilConnectCount: 3);
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final stopwatch = Stopwatch()..start();
    final result = await manager.printTicket(List<int>.filled(1, 9));
    stopwatch.stop();

    expect(result, PosPrintResult.success);
    expect(backend.connectCount, 4);
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(500));
  });
}
