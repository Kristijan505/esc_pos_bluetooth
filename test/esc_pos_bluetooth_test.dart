import 'dart:async';
import 'dart:typed_data';

import 'package:esc_pos_bluetooth/src/enums.dart';
import 'package:esc_pos_bluetooth/src/printer_bluetooth_manager.dart';
import 'package:flutter_bluetooth_basic/flutter_bluetooth_basic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

class FakePrinterBluetoothBackend implements PrinterBluetoothBackend {
  FakePrinterBluetoothBackend({
    this.failWritesOnChunkSizes = const <int>{},
    this.failWritesUntilConnectCount = 0,
    this.failConnect = false,
    this.writeGate,
    this.queryStatusResponse,
    this.queryStatusError,
    this.queryStatusGate,
  });

  final BehaviorSubject<bool> _isScanning = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<List<BluetoothDevice>> _scanResults =
      BehaviorSubject<List<BluetoothDevice>>.seeded(<BluetoothDevice>[]);
  final BehaviorSubject<int?> _state = BehaviorSubject<int?>.seeded(
    BluetoothManager.DISCONNECTED,
  );

  final Set<int> failWritesOnChunkSizes;
  final int failWritesUntilConnectCount;
  final bool failConnect;
  final Completer<void>? writeGate;
  final Uint8List? queryStatusResponse;
  final Object? queryStatusError;
  final Completer<void>? queryStatusGate;

  final List<String> log = <String>[];
  final List<int> writeSizes = <int>[];
  // Snapshots of the actual bytes received (not just their length), so a
  // test can tell whether a caller's later mutation of its own list leaked
  // into what the backend saw.
  final List<List<int>> receivedWrites = <List<int>>[];
  final List<List<int>> receivedQueryRequests = <List<int>>[];
  int connectCount = 0;
  int disconnectCount = 0;
  int writeCount = 0;
  int queryStatusCount = 0;

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

    if (failConnect) {
      throw Exception('forced connect failure for connect-failure test');
    }

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
    receivedWrites.add(List<int>.from(bytes));
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

  @override
  Future<Uint8List> queryStatus(
    List<int> request, {
    required Duration timeout,
    required Duration grace,
    required Duration quietPeriod,
    required int maxBytes,
  }) async {
    queryStatusCount++;
    receivedQueryRequests.add(List<int>.from(request));
    log.add('queryStatus:${request.length}');

    if (queryStatusGate != null && !queryStatusGate!.isCompleted) {
      await queryStatusGate!.future;
    }

    if (queryStatusError != null) {
      throw queryStatusError!;
    }

    return queryStatusResponse ?? Uint8List(0);
  }

  Future<void> dispose() async {
    await _isScanning.close();
    await _scanResults.close();
    await _state.close();
  }
}

/// A backend that leaves [PrinterBluetoothBackend.queryStatus] unoverridden,
/// to exercise its default `UnsupportedError` body. `extends` (rather than
/// `implements`, as [FakePrinterBluetoothBackend] does) is what makes that
/// default body apply here.
class _MinimalBackend extends PrinterBluetoothBackend {
  @override
  Stream<bool> get isScanningStream => const Stream<bool>.empty();

  @override
  Stream<List<BluetoothDevice>> get scanResults =>
      const Stream<List<BluetoothDevice>>.empty();

  @override
  Stream<int?> get state => const Stream<int?>.empty();

  @override
  Future<void> startScan(Duration timeout) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(BluetoothDevice device) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> writeData(List<int> bytes) async {}
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
    expect(emissions.last.map((printer) => printer.address).toList(), <String>[
      'AA:11',
      'BB:22',
    ]);
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

    expect(backend.log, <String>[
      'stopScan',
      'connect:AA:11',
      'write:8',
      'disconnect',
      'stopScan',
      'connect:AA:11',
      'write:4',
      'disconnect',
    ]);
  });

  // Neither layer resends a ticket any more: the native side stopped
  // restarting from byte 0 (which reprinted the part the printer had already
  // put on paper), and this one stops after a single attempt.  A failed write
  // reaches the caller, who asks the user whether to print again.
  test('printTicket sends the payload once and never splits it', () async {
    final backend = FakePrinterBluetoothBackend(
      failWritesOnChunkSizes: <int>{300},
    );
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final result = await manager.printTicket(List<int>.filled(300, 7));

    expect(
      result,
      PosPrintResult.timeout,
      reason:
          'a failed write is reported as a returned result, not thrown - '
          'printTicket/writeBytes is a documented contract for callers '
          'without a try/catch',
    );
    expect(
      manager.lastError,
      contains('forced write failure'),
      reason: 'the raw error stays inspectable for diagnostics',
    );

    expect(backend.writeSizes, <int>[
      300,
    ], reason: 'full payload once, never split into smaller chunks');
    expect(backend.connectCount, 1, reason: 'a single attempt');
    expect(
      backend.disconnectCount,
      greaterThanOrEqualTo(1),
      reason: 'the socket is released even when the write fails',
    );
  });

  test('printTicket does not reconnect after a failed write', () async {
    // Prije bi treci pokusaj uspio i ispis bi izasao dvaput; sada prvi
    // neuspjeh zavrsava posao.
    final backend = FakePrinterBluetoothBackend(failWritesUntilConnectCount: 2);
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final stopwatch = Stopwatch()..start();
    final result = await manager.printTicket(List<int>.filled(1, 9));
    stopwatch.stop();

    expect(result, PosPrintResult.timeout);
    expect(manager.lastError, contains('forced write failure'));
    expect(backend.connectCount, 1, reason: 'no second attempt');
    expect(backend.writeCount, 1);
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(2000),
      reason: 'no backoff waits, because there is nothing to back off to',
    );
  });

  test('printTicket surfaces a connect failure without writing', () async {
    final backend = FakePrinterBluetoothBackend(failConnect: true);
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final result = await manager.printTicket(List<int>.filled(4, 1));

    expect(
      result,
      PosPrintResult.timeout,
      reason: 'a failed connect is reported as a returned result to the caller',
    );
    expect(manager.lastError, contains('forced connect failure'));

    expect(
      backend.writeCount,
      0,
      reason: 'writeData must never run after a failed connect',
    );
    expect(
      backend.disconnectCount,
      greaterThanOrEqualTo(1),
      reason: 'the socket is still released even though connect failed',
    );
  });

  test('queryStatus returns bytes and connects/disconnects', () async {
    final response = Uint8List.fromList(<int>[0x12, 0x34]);
    final backend = FakePrinterBluetoothBackend(queryStatusResponse: response);
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final result = await manager.queryStatus(<int>[0x10, 0x04, 0x01]);

    expect(result, response);
    expect(backend.log, <String>[
      'stopScan',
      'connect:AA:11',
      'queryStatus:3',
      'disconnect',
    ]);
  });

  test('queryStatus throws StateError without a selected printer', () async {
    final backend = FakePrinterBluetoothBackend();
    final manager = PrinterBluetoothManager(backend: backend);

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    // Passed as an already-created future (not a closure): queryStatus
    // must return a failed future here rather than throw synchronously, so
    // the error arrives the same way no matter how the caller awaits it.
    expect(manager.queryStatus(<int>[0x10, 0x04, 0x01]), throwsStateError);
  });

  test(
    'queryStatus propagates a backend error and still disconnects',
    () async {
      final backend = FakePrinterBluetoothBackend(
        queryStatusError: Exception('forced query failure'),
      );
      final manager = PrinterBluetoothManager(backend: backend);
      manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

      addTearDown(() async {
        await manager.dispose();
        await backend.dispose();
      });

      await expectLater(
        manager.queryStatus(<int>[0x10, 0x04, 0x01]),
        throwsA(isException),
      );

      expect(
        backend.disconnectCount,
        greaterThanOrEqualTo(1),
        reason: 'the socket is released even when the query fails',
      );
    },
  );

  test(
    'queryStatus sent while printing waits for the print job to finish',
    () async {
      final gate = Completer<void>();
      final backend = FakePrinterBluetoothBackend(
        writeGate: gate,
        queryStatusResponse: Uint8List.fromList(<int>[0x00]),
      );
      final manager = PrinterBluetoothManager(backend: backend);
      manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

      addTearDown(() async {
        await manager.dispose();
        await backend.dispose();
      });

      final printFuture = manager.printTicket(List<int>.filled(4, 1));
      final statusFuture = manager.queryStatus(<int>[0x10, 0x04, 0x01]);

      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(
        backend.queryStatusCount,
        0,
        reason: 'the print job holds the queue until the write gate opens',
      );
      expect(backend.connectCount, 1);

      gate.complete();

      expect(await printFuture, PosPrintResult.success);
      expect(await statusFuture, Uint8List.fromList(<int>[0x00]));

      expect(backend.log, <String>[
        'stopScan',
        'connect:AA:11',
        'write:4',
        'disconnect',
        'stopScan',
        'connect:AA:11',
        'queryStatus:3',
        'disconnect',
      ]);
    },
  );

  test('queryStatus returns an empty Uint8List for a silent printer', () async {
    final backend = FakePrinterBluetoothBackend();
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    final result = await manager.queryStatus(<int>[0x10, 0x04, 0x01]);

    expect(result, isA<Uint8List>());
    expect(result, isEmpty);
  });

  test('mutating the bytes list after printTicket() does not change what the '
      'backend receives', () async {
    final gate = Completer<void>();
    final backend = FakePrinterBluetoothBackend(writeGate: gate);
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    // A first job occupies the gate so the second job (whose bytes we're
    // about to mutate) is still sitting in _pendingJobs, not yet running,
    // when the mutation happens.
    final blocker = manager.printTicket(List<int>.filled(1, 0xAA));

    final bytes = List<int>.of(<int>[1, 2, 3]);
    final second = manager.printTicket(bytes);

    // Mutate the caller's own list after enqueuing but before the job runs.
    bytes[0] = 0xFF;
    bytes.add(4);

    gate.complete();

    expect(await blocker, PosPrintResult.success);
    expect(await second, PosPrintResult.success);

    expect(
      backend.receivedWrites[1],
      <int>[1, 2, 3],
      reason:
          'the job must have snapshotted the bytes when printTicket() was '
          'called, not when it later ran',
    );
  });

  test('mutating the request list after queryStatus() does not change what '
      'the backend receives', () async {
    final gate = Completer<void>();
    final backend = FakePrinterBluetoothBackend(
      writeGate: gate,
      queryStatusResponse: Uint8List.fromList(<int>[0x00]),
    );
    final manager = PrinterBluetoothManager(backend: backend);
    manager.selectPrinter(PrinterBluetooth(_device('AA:11', 'Printer 1')));

    addTearDown(() async {
      await manager.dispose();
      await backend.dispose();
    });

    // printTicket occupies the gate so the queued queryStatus job (whose
    // request we're about to mutate) is still waiting, not yet running.
    final blocker = manager.printTicket(List<int>.filled(1, 0xAA));

    final request = List<int>.of(<int>[0x10, 0x04, 0x01]);
    final status = manager.queryStatus(request);

    // Mutate the caller's own list after enqueuing but before the job runs.
    request[0] = 0xFF;
    request.add(0x99);

    gate.complete();

    expect(await blocker, PosPrintResult.success);
    await status;

    expect(
      backend.receivedQueryRequests.single,
      <int>[0x10, 0x04, 0x01],
      reason:
          'the job must have snapshotted the request when queryStatus() '
          'was called, not when it later ran',
    );
  });

  test(
    'the default PrinterBluetoothBackend.queryStatus throws UnsupportedError',
    () {
      final backend = _MinimalBackend();

      expect(
        () => backend.queryStatus(
          <int>[0x10, 0x04, 0x01],
          timeout: const Duration(milliseconds: 600),
          grace: const Duration(milliseconds: 50),
          quietPeriod: const Duration(milliseconds: 150),
          maxBytes: 16,
        ),
        throwsUnsupportedError,
      );
    },
  );
}
