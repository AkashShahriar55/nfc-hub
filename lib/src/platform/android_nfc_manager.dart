import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The state of the phone's built-in NFC adapter.
enum NfcState {
  /// NFC hardware is present and turned on.
  enabled,

  /// NFC hardware is present but turned off.
  disabled,

  /// The device has no NFC hardware.
  noHardware,
}

NfcState _nfcStateFromWire(String value) {
  switch (value) {
    case 'enabled':
      return NfcState.enabled;
    case 'disabled':
      return NfcState.disabled;
    case 'noHardware':
      return NfcState.noHardware;
  }
  throw ArgumentError.value(value, 'value', 'Unknown NfcState');
}

/// A tag discovered by the phone's built-in NFC antenna.
///
/// Fields beyond [handle], [techList] and [uid] are only populated when the
/// underlying technology exposes them; all others are null.
class NfcTagDiscovery {
  const NfcTagDiscovery({
    required this.handle,
    required this.techList,
    required this.uid,
    this.atqa,
    this.sak,
    this.atqb,
    this.idm,
    this.pmm,
    this.historicalBytes,
  });

  /// Opaque handle identifying this tag for the lifetime of its presence in
  /// the field. Used to address subsequent transceive/auth/read calls; once
  /// the tag leaves the field, those calls fail with a `TAG_LOST` platform
  /// error (surfaced higher up as `TagLostException`) rather than a separate
  /// loss event.
  final int handle;

  /// Android tech-class names for this tag (e.g. `IsoDep`, `MifareClassic`).
  final List<String> techList;

  final Uint8List uid;
  final Uint8List? atqa;
  final int? sak;
  final Uint8List? atqb;
  final Uint8List? idm;
  final Uint8List? pmm;
  final Uint8List? historicalBytes;
}

Uint8List? _bytesOrNull(Object? value) {
  if (value == null) return null;
  return _bytes(value);
}

Uint8List _bytes(Object value) {
  if (value is Uint8List) return value;
  if (value is List) return Uint8List.fromList(value.cast<int>());
  throw ArgumentError.value(value, 'value', 'Expected byte data');
}

NfcTagDiscovery _discoveryFromWire(Map<Object?, Object?> map) {
  return NfcTagDiscovery(
    handle: map['handle'] as int,
    techList: (map['techList'] as List).cast<String>(),
    uid: _bytes(map['uid'] as Object),
    atqa: _bytesOrNull(map['atqa']),
    sak: map['sak'] as int?,
    atqb: _bytesOrNull(map['atqb']),
    idm: _bytesOrNull(map['idm']),
    pmm: _bytesOrNull(map['pmm']),
    historicalBytes: _bytesOrNull(map['historicalBytes']),
  );
}

/// A thin, mechanical Dart wrapper over the platform channels the Android
/// side speaks for the phone's built-in NFC antenna.
///
/// This class performs marshalling only: it turns typed Dart calls into
/// method-channel calls, and demultiplexes the single event-channel stream
/// into typed per-kind streams. It makes no decisions about tag
/// identification, connection state, or protocol logic -- that lives
/// elsewhere.
class AndroidNfcManager {
  AndroidNfcManager({
    @visibleForTesting MethodChannel? methodChannel,
    @visibleForTesting EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel('nfc_hub'),
        _event = eventChannel ?? const EventChannel('nfc_hub/events') {
    _sub = _event
        .receiveBroadcastStream()
        .listen(_onEvent, onError: _onEventError);
  }

  final MethodChannel _method;
  final EventChannel _event;
  late final StreamSubscription<Object?> _sub;

  final _discoveriesController = StreamController<NfcTagDiscovery>.broadcast();
  final _nfcStateChangesController = StreamController<NfcState>.broadcast();

  /// Tags discovered by the phone's NFC antenna.
  Stream<NfcTagDiscovery> get discoveries => _discoveriesController.stream;

  /// Changes to the phone's NFC adapter state.
  Stream<NfcState> get nfcStateChanges => _nfcStateChangesController.stream;

  void _onEvent(Object? event) {
    Object? type;
    try {
      final map = (event as Map).cast<Object?, Object?>();
      type = map['type'];
      switch (type) {
        case 'tagDiscovered':
          _discoveriesController.add(_discoveryFromWire(map));
        case 'nfcStateChanged':
          _nfcStateChangesController
              .add(_nfcStateFromWire(map['state'] as String));
      }
    } catch (error, stackTrace) {
      // A malformed event must not tear down the single underlying
      // subscription -- surface it as a stream error instead, so later
      // well-formed events keep flowing.
      switch (type) {
        case 'tagDiscovered':
          _discoveriesController.addError(error, stackTrace);
        case 'nfcStateChanged':
          _nfcStateChangesController.addError(error, stackTrace);
        default:
          // The type itself couldn't be read (or is otherwise unknown):
          // fan out to both streams, matching _onEventError.
          _onEventError(error, stackTrace);
      }
    }
  }

  void _onEventError(Object error, StackTrace stackTrace) {
    _discoveriesController.addError(error, stackTrace);
    _nfcStateChangesController.addError(error, stackTrace);
  }

  /// Sends raw command bytes to the tag identified by [handle] over the
  /// given Android tech ([tech], e.g. `IsoDep`) and returns the response.
  Future<Uint8List> transceive(int handle, String tech, Uint8List data) async {
    // Use Object? (not Uint8List) so a Kotlin side that returns a generic
    // int list instead of a ByteArray doesn't crash inside invokeMethod's
    // own internal cast, before _bytes() gets a chance to normalize it.
    final result = await _method.invokeMethod<Object?>('nfcTransceive', {
      'handle': handle,
      'tech': tech,
      'data': data,
    });
    if (result == null) {
      throw StateError('nfcTransceive returned null');
    }
    return _bytes(result);
  }

  /// Authenticates a MIFARE Classic sector with a key A/B.
  Future<void> mifareAuthenticate(
      int handle, int sector, bool keyA, Uint8List key) async {
    await _method.invokeMethod<void>('nfcMifareAuth', {
      'handle': handle,
      'sector': sector,
      'keyA': keyA,
      'key': key,
    });
  }

  /// Reads a single MIFARE Classic block after authentication.
  Future<Uint8List> mifareReadBlock(int handle, int block) async {
    // See transceive() above for why this is Object? rather than Uint8List.
    final result = await _method.invokeMethod<Object?>('nfcMifareReadBlock', {
      'handle': handle,
      'block': block,
    });
    if (result == null) {
      throw StateError('nfcMifareReadBlock returned null');
    }
    return _bytes(result);
  }

  /// Starts Android reader mode, enabling tag discovery events.
  Future<void> startReaderMode() {
    return _method.invokeMethod<void>('nfcStartReaderMode');
  }

  /// Stops Android reader mode.
  Future<void> stopReaderMode() {
    return _method.invokeMethod<void>('nfcStopReaderMode');
  }

  /// Reads the current state of the phone's NFC adapter.
  Future<NfcState> getNfcState() async {
    final result = await _method.invokeMethod<String>('getNfcState');
    return _nfcStateFromWire(result as String);
  }

  /// Opens the system NFC settings screen.
  Future<void> openNfcSettings() {
    return _method.invokeMethod<void>('openNfcSettings');
  }

  /// Releases the underlying event-channel subscription and closes the
  /// typed streams. After calling this, the manager must not be used again.
  Future<void> dispose() async {
    await _sub.cancel();
    await _discoveriesController.close();
    await _nfcStateChangesController.close();
  }
}
