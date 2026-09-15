/*
 * esc_pos_bluetooth
 * Created by Andrey Ushakov
 *
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_basic/flutter_bluetooth_basic.dart';
import 'package:rxdart/rxdart.dart';

import './enums.dart';

/// Bluetooth printer
class PrinterBluetooth {
  PrinterBluetooth(this._device);

  final BluetoothDevice _device;

  String? get name => _device.name;
  String? get address => _device.address;
  int? get type => _device.type;
}

/// Internal transport contract used by the manager and tests.
abstract class PrinterBluetoothBackend {
  Stream<bool> get isScanningStream;
  Stream<List<BluetoothDevice>> get scanResults;
  Stream<int?> get state;

  Future<void> startScan(Duration timeout);
  Future<void> stopScan();
  Future<void> connect(BluetoothDevice device);
  Future<void> disconnect();
  Future<void> writeData(List<int> bytes);

  /// Sends [request] to the printer and returns its raw reply, or an empty
  /// [Uint8List] if the printer stayed silent. See
  /// [PrinterBluetoothManager.queryStatus] for the full contract.
  ///
  /// This has a default body - rather than being abstract - so that a
  /// subclass which `extends` this class (instead of `implements`ing it)
  /// keeps compiling without adding an override. It throws
  /// [UnsupportedError] because a backend that predates status queries has
  /// no way to actually perform one.
  Future<Uint8List> queryStatus(
    List<int> request, {
    required Duration timeout,
    required Duration grace,
    required Duration quietPeriod,
    required int maxBytes,
  }) {
    throw UnsupportedError('$runtimeType does not support queryStatus.');
  }
}

class BluetoothManagerBackend implements PrinterBluetoothBackend {
  BluetoothManagerBackend(this._manager);

  final BluetoothManager _manager;

  @override
  Stream<bool> get isScanningStream => _manager.isScanning;

  @override
  Stream<List<BluetoothDevice>> get scanResults => _manager.scanResults;

  @override
  Stream<int?> get state => _manager.state;

  @override
  Future<void> connect(BluetoothDevice device) => _manager.connect(device);

  @override
  Future<void> disconnect() => _manager.disconnect();

  @override
  Future<void> startScan(Duration timeout) =>
      _manager.startScan(timeout: timeout);

  @override
  Future<void> stopScan() => _manager.stopScan();

  @override
  Future<void> writeData(List<int> bytes) => _manager.writeData(bytes);

  @override
  Future<Uint8List> queryStatus(
    List<int> request, {
    required Duration timeout,
    required Duration grace,
    required Duration quietPeriod,
    required int maxBytes,
  }) => _manager.queryStatus(
    request,
    timeout: timeout,
    grace: grace,
    quietPeriod: quietPeriod,
    maxBytes: maxBytes,
  );
}

/// A single job on [PrinterBluetoothManager]'s queue - either a print or a
/// status query. `run` carries the job's own logic as a closure so the
/// queue itself stays generic over what a job actually does and what it
/// completes with.
class _QueuedJob<T> {
  _QueuedJob({required this.printer, required this.run});

  final PrinterBluetooth printer;
  final Future<T> Function() run;
  final Completer<T> completer = Completer<T>();
}

/// Printer Bluetooth Manager
class PrinterBluetoothManager {
  PrinterBluetoothManager({PrinterBluetoothBackend? backend})
    : _backend = backend ?? BluetoothManagerBackend(BluetoothManager.instance);

  final PrinterBluetoothBackend _backend;

  final Duration _postSendSettleDelay = const Duration(seconds: 2);

  final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);
  Stream<bool> get isScanningStream => _isScanning.stream;

  final BehaviorSubject<List<PrinterBluetooth>> _scanResults =
      BehaviorSubject.seeded(<PrinterBluetooth>[]);
  Stream<List<PrinterBluetooth>> get scanResults => _scanResults.stream;

  final Map<String, PrinterBluetooth> _knownPrinters =
      LinkedHashMap<String, PrinterBluetooth>();
  StreamSubscription<List<BluetoothDevice>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  bool _hasObservedScanningState = false;

  final List<_QueuedJob<dynamic>> _pendingJobs = <_QueuedJob<dynamic>>[];
  bool _isProcessingJobs = false;
  PrinterBluetooth? _selectedPrinter;

  /// The raw error from the most recent print job, or `null` after a job
  /// that never failed (or hasn't run yet).
  ///
  /// `printTicket`/`writeBytes` return a `PosPrintResult`, not the
  /// exception itself, so this is the only place callers (and us, when
  /// debugging) can see WHY a job failed - `device_disconnected` vs.
  /// `job_timeout` from the native side matters when tracking down a
  /// printer issue. Cleared at the start of every job, set right before a
  /// failed job's result is returned.
  String? lastError;

  void startScan(Duration timeout) {
    unawaited(_restartScan(timeout));
  }

  void stopScan() {
    unawaited(_stopScanInternal());
  }

  void selectPrinter(PrinterBluetooth printer) {
    _selectedPrinter = printer;
  }

  // `chunkSizeBytes` and `queueSleepTimeMs` are no longer read: the native
  // layer now owns chunking and pacing (Android sends fixed 128-byte chunks
  // with a 50ms pause between them; see flutter_bluetooth_basic's
  // writeData/sendInChunks). The parameters are kept only so existing
  // callers outside this repo (e.g. RedCodeCMS, Croatian sports museum CMS,
  // both pinned to `ref: master` of this fork) keep compiling unchanged.
  Future<PosPrintResult> writeBytes(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) {
    return _enqueuePrintJob(
      bytes,
      chunkSizeBytes: chunkSizeBytes,
      queueSleepTimeMs: queueSleepTimeMs,
    );
  }

  // See the note on `writeBytes` above: `chunkSizeBytes` and
  // `queueSleepTimeMs` are ignored today (native layer chunks/paces
  // writes) and are kept only for backwards compatibility with existing
  // callers.
  Future<PosPrintResult> printTicket(
    List<int> bytes, {
    int chunkSizeBytes = 256, // Optimal chunk size for most thermal printers
    int queueSleepTimeMs = 50, // Balanced sleep time for reliable transmission
  }) {
    if (bytes.isEmpty) {
      return Future<PosPrintResult>.value(PosPrintResult.ticketEmpty);
    }

    return _enqueuePrintJob(
      bytes,
      chunkSizeBytes: chunkSizeBytes,
      queueSleepTimeMs: queueSleepTimeMs,
    );
  }

  /// Sends [request] to the selected printer's status query line and
  /// returns its raw reply.
  ///
  /// An empty [Uint8List] result means the printer stayed silent within
  /// [timeout] - that's a normal outcome (some queries, or some printers,
  /// never answer), not an error.
  ///
  /// Like [printTicket], every call connects to the selected printer first
  /// and disconnects again afterwards, and goes through the same job queue,
  /// so a status query and a print job never share the wire at the same
  /// time - whichever was requested first runs first.
  ///
  /// Unlike [printTicket], failures are not swallowed into a result value:
  /// this is a new API with no external caller relying on a never-throws
  /// contract, so a failed connect or backend error is rethrown to the
  /// caller, and calling this without a previously [selectPrinter]-ed
  /// printer throws a [StateError]. Invalid arguments ([timeout], [grace],
  /// [quietPeriod], [maxBytes]) are validated by the backend and any
  /// [ArgumentError] it raises reaches the caller unchanged.
  ///
  /// ESC/POS status replies carry no tag saying which request they answer,
  /// so matching a reply to the request that produced it - by its fixed
  /// bits - is the caller's responsibility.
  Future<Uint8List> queryStatus(
    List<int> request, {
    Duration timeout = const Duration(milliseconds: 600),
    Duration grace = const Duration(milliseconds: 50),
    Duration quietPeriod = const Duration(milliseconds: 150),
    int maxBytes = 16,
  }) {
    final printer = _selectedPrinter;
    if (printer == null) {
      throw StateError(
        'No printer selected. Call selectPrinter() before queryStatus().',
      );
    }

    final job = _QueuedJob<Uint8List>(
      printer: printer,
      run: () => _runQueryStatusJob(
        printer,
        request,
        timeout: timeout,
        grace: grace,
        quietPeriod: quietPeriod,
        maxBytes: maxBytes,
      ),
    );

    _pendingJobs.add(job);
    _scheduleQueueProcessing();
    return job.completer.future;
  }

  Future<void> dispose() async {
    await _stopScanInternal();
    await _backend.disconnect();
    await _isScanning.close();
    await _scanResults.close();
  }

  Future<void> _restartScan(Duration timeout) async {
    await _stopScanInternal();

    _knownPrinters.clear();
    _scanResults.add(<PrinterBluetooth>[]);
    _isScanning.add(true);

    _scanResultsSubscription = _backend.scanResults.listen((devices) {
      _mergeScanResults(devices);
    });

    _isScanningSubscription = _backend.isScanningStream.listen((current) {
      _isScanning.add(current);
      if (!_hasObservedScanningState) {
        _hasObservedScanningState = true;
        return;
      }

      if (!current) {
        _cancelScanSubscriptions();
      }
    });

    try {
      await _backend.startScan(timeout);
    } catch (_) {
      _isScanning.add(false);
      await _cancelScanSubscriptions();
      rethrow;
    }
  }

  Future<void> _stopScanInternal() async {
    await _backend.stopScan();
    await _cancelScanSubscriptions();
    _hasObservedScanningState = false;
    _isScanning.add(false);
  }

  Future<void> _cancelScanSubscriptions() async {
    final scanResultsSubscription = _scanResultsSubscription;
    _scanResultsSubscription = null;
    await scanResultsSubscription?.cancel();

    final isScanningSubscription = _isScanningSubscription;
    _isScanningSubscription = null;
    await isScanningSubscription?.cancel();
    _hasObservedScanningState = false;
  }

  void _mergeScanResults(List<BluetoothDevice> devices) {
    var changed = false;

    for (final device in devices) {
      final address = device.address;
      if (address == null || address.isEmpty) {
        continue;
      }

      final printer = PrinterBluetooth(device);
      final existing = _knownPrinters[address];
      if (existing == null ||
          existing.address != printer.address ||
          existing.name != printer.name ||
          existing.type != printer.type) {
        _knownPrinters[address] = printer;
        changed = true;
      }
    }

    if (changed) {
      _scanResults.add(_knownPrinters.values.toList(growable: false));
    }
  }

  Future<PosPrintResult> _enqueuePrintJob(
    List<int> bytes, {
    required int chunkSizeBytes,
    required int queueSleepTimeMs,
  }) {
    final printer = _selectedPrinter;
    if (printer == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    }

    final job = _QueuedJob<PosPrintResult>(
      printer: printer,
      run: () => _runPrintJob(printer, List<int>.unmodifiable(bytes)),
    );

    _pendingJobs.add(job);
    _scheduleQueueProcessing();
    return job.completer.future;
  }

  void _scheduleQueueProcessing() {
    if (_isProcessingJobs) {
      return;
    }

    _isProcessingJobs = true;
    _processQueue();
  }

  Future<void> _processQueue() async {
    try {
      while (_pendingJobs.isNotEmpty) {
        final job = _pendingJobs.removeAt(0);
        try {
          final result = await job.run();
          if (!job.completer.isCompleted) {
            job.completer.complete(result);
          }
        } catch (error, stackTrace) {
          if (!job.completer.isCompleted) {
            job.completer.completeError(error, stackTrace);
          }
        }
      }
    } finally {
      _isProcessingJobs = false;
    }
  }

  Future<PosPrintResult> _runPrintJob(
    PrinterBluetooth printer,
    List<int> bytes,
  ) async {
    await _stopScanInternal();

    lastError = null;

    // Connect once, send the full payload once, and stop there.
    //
    // The retry loop that stood here re-sent the ticket from its first byte,
    // but the printer had already put the beginning of the receipt on paper —
    // so a broken connection produced a receipt with a repeated section
    // instead of a clean failure.  A failed job now surfaces to the caller,
    // and the user decides whether to print again.
    //
    // The failure surfaces as a returned PosPrintResult, never a thrown
    // exception: printTicket/writeBytes are a documented contract used by
    // callers outside this repo (RedCodeCMS, the sports museum CMS) that
    // do `final res = await printTicket(...)` without a try/catch. Throwing
    // here would turn a broken Bluetooth link into an uncaught async error
    // for them.
    try {
      await _connectAndAwait(printer);
      await _backend.writeData(bytes);

      if (_postSendSettleDelay.inMilliseconds > 0) {
        await Future<void>.delayed(_postSendSettleDelay);
      }

      return PosPrintResult.success;
    } catch (error) {
      lastError = error.toString();

      if (kDebugMode) {
        debugPrint('esc_pos_bluetooth: print job failed: $lastError');
      }

      return PosPrintResult.timeout;
    } finally {
      await _safeDisconnect();
    }
  }

  // Unlike _runPrintJob, this never swallows a failure into a result value:
  // queryStatus is a new API with no external caller depending on a
  // never-throws contract, so a failed connect or backend error is left to
  // propagate to whoever is awaiting the job's completer. `lastError` is
  // intentionally left untouched here - it documents print job failures
  // only.
  Future<Uint8List> _runQueryStatusJob(
    PrinterBluetooth printer,
    List<int> request, {
    required Duration timeout,
    required Duration grace,
    required Duration quietPeriod,
    required int maxBytes,
  }) async {
    await _stopScanInternal();

    try {
      await _connectAndAwait(printer);
      return await _backend.queryStatus(
        request,
        timeout: timeout,
        grace: grace,
        quietPeriod: quietPeriod,
        maxBytes: maxBytes,
      );
    } finally {
      await _safeDisconnect();
    }
  }

  Future<void> _connectAndAwait(PrinterBluetooth printer) async {
    // Native connect() is blocking on both platforms:
    //  - Android: socket.connect() blocks until RFCOMM is up
    //  - iOS: CoreBluetooth connect waits for didConnect + service discovery
    // No need to poll the state stream afterwards.
    await _backend.connect(printer._device);
  }

  Future<void> _safeDisconnect() async {
    try {
      await _backend.disconnect();
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
