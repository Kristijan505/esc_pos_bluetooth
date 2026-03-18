/*
 * esc_pos_bluetooth
 * Created by Andrey Ushakov
 *
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:collection';

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
}

class _QueuedPrintJob {
  _QueuedPrintJob({
    required this.printer,
    required this.bytes,
    required this.chunkSizeBytes,
    required this.queueSleepTimeMs,
  });

  final PrinterBluetooth printer;
  final List<int> bytes;
  final int chunkSizeBytes;
  final int queueSleepTimeMs;
  final Completer<PosPrintResult> completer = Completer<PosPrintResult>();
}

class _PrinterJobFailure implements Exception {
  const _PrinterJobFailure(this.result);

  final PosPrintResult result;
}

/// Printer Bluetooth Manager
class PrinterBluetoothManager {
  PrinterBluetoothManager({PrinterBluetoothBackend? backend})
      : _backend = backend ??
            BluetoothManagerBackend(BluetoothManager.instance);

  final PrinterBluetoothBackend _backend;
  final Duration _connectTimeout = const Duration(seconds: 12);
  final List<Duration> _retryBackoffs = const <Duration>[
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];
  final Duration _postSendSettleDelay = const Duration(seconds: 1);

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

  final List<_QueuedPrintJob> _pendingJobs = <_QueuedPrintJob>[];
  bool _isProcessingJobs = false;
  PrinterBluetooth? _selectedPrinter;

  void startScan(Duration timeout) {
    unawaited(_restartScan(timeout));
  }

  void stopScan() {
    unawaited(_stopScanInternal());
  }

  void selectPrinter(PrinterBluetooth printer) {
    _selectedPrinter = printer;
  }

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

    final job = _QueuedPrintJob(
      printer: printer,
      bytes: List<int>.unmodifiable(bytes),
      chunkSizeBytes: chunkSizeBytes,
      queueSleepTimeMs: queueSleepTimeMs,
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
          final result = await _runPrintJob(job);
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

  Future<PosPrintResult> _runPrintJob(_QueuedPrintJob job) async {
    await _stopScanInternal();
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryBackoffs[attempt - 1]);
      }

      try {
        final result = await _runSingleAttempt(job);
        if (result == PosPrintResult.success) {
          return result;
        }
      } on _PrinterJobFailure catch (failure) {
        if (failure.result != PosPrintResult.timeout) {
          return failure.result;
        }
      } catch (_) {
        // Swallow and retry below.
      }
    }

    return PosPrintResult.timeout;
  }

  Future<PosPrintResult> _runSingleAttempt(_QueuedPrintJob job) async {
    final chunkSizes = _chunkSizes(job.chunkSizeBytes);
    _PrinterJobFailure? lastFailure;

    for (final chunkSize in chunkSizes) {
      try {
        await _connectAndAwait(job.printer);
        await _sendWithChunkSize(job.bytes, chunkSize, job.queueSleepTimeMs);
        return PosPrintResult.success;
      } on _PrinterJobFailure catch (failure) {
        lastFailure = failure;
      } catch (_) {
        lastFailure = const _PrinterJobFailure(PosPrintResult.timeout);
      } finally {
        await _safeDisconnect();
      }
    }

    throw lastFailure ?? const _PrinterJobFailure(PosPrintResult.timeout);
  }

  List<int> _chunkSizes(int preferredChunkSize) {
    final ordered = <int>[
      if (preferredChunkSize > 0) preferredChunkSize,
      128,
      64,
    ];

    final unique = <int>[];
    for (final size in ordered) {
      if (!unique.contains(size)) {
        unique.add(size);
      }
    }
    return unique;
  }

  Future<void> _connectAndAwait(PrinterBluetooth printer) async {
    await _backend.connect(printer._device);
    await _waitForState(
      (state) => state == BluetoothManager.CONNECTED,
      timeout: _connectTimeout,
      failureResult: PosPrintResult.timeout,
    );
  }

  Future<void> _sendWithChunkSize(
    List<int> bytes,
    int chunkSizeBytes,
    int queueSleepTimeMs,
  ) async {
    final chunks = <List<int>>[];
    final effectiveChunkSize = chunkSizeBytes <= 0 ? 1 : chunkSizeBytes;
    for (var index = 0; index < bytes.length; index += effectiveChunkSize) {
      final end =
          (index + effectiveChunkSize < bytes.length)
              ? index + effectiveChunkSize
              : bytes.length;
      chunks.add(bytes.sublist(index, end));
    }

    for (final chunk in chunks) {
      await _backend.writeData(chunk);
      if (queueSleepTimeMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: queueSleepTimeMs));
      }
    }

    if (_postSendSettleDelay.inMilliseconds > 0) {
      await Future<void>.delayed(_postSendSettleDelay);
    }
  }

  Future<void> _waitForState(
    bool Function(int? state) predicate, {
    required Duration timeout,
    required PosPrintResult failureResult,
  }) async {
    final completer = Completer<void>();
    StreamSubscription<int?>? subscription;

    subscription = _backend.state.listen(
      (state) {
        if (state == null) {
          return;
        }

        if (predicate(state)) {
          if (!completer.isCompleted) {
            completer.complete();
          }
          if (subscription != null) {
            unawaited(subscription.cancel());
          }
        } else if (state == BluetoothManager.DISCONNECTED) {
          if (!completer.isCompleted) {
            completer.completeError(_PrinterJobFailure(failureResult));
          }
          if (subscription != null) {
            unawaited(subscription.cancel());
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      throw _PrinterJobFailure(failureResult);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _safeDisconnect() async {
    try {
      await _backend.disconnect();
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
