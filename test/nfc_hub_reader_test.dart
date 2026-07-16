import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';

/// A fake NfcHub the facade is built over. Records the last `from` filter,
/// exposes a controllable tag stream, and counts passthrough calls.
class _FakeNfcHub extends NfcHub {
  final tagController = StreamController<TagDriver>.broadcast();
  final stateController = StreamController<CcidConnectionState>.broadcast();

  CcidSourceFilter? lastFrom;
  bool tagStreamCalled = false;
  bool availableReturn = true;
  int openNfcSettingsCalls = 0;
  int connectionStateCalls = 0;

  @override
  Stream<TagDriver> tagStream({CcidSourceFilter? from}) {
    tagStreamCalled = true;
    lastFrom = from;
    return tagController.stream;
  }

  @override
  Stream<CcidConnectionState> connectionState() {
    connectionStateCalls++;
    return stateController.stream;
  }

  @override
  Future<bool> isAvailable() async => availableReturn;

  @override
  Future<void> openNfcSettings() async {
    openNfcSettingsCalls++;
  }
}

void main() {
  test('NfcSource.builtIn() maps to CcidSourceFilter.builtInNfc()', () {
    expect(const NfcSource.builtIn().toFilter(),
        equals(const CcidSourceFilter.builtInNfc()));
  });

  test('NfcSource.reader(name) maps to CcidSourceFilter.reader(name)', () {
    expect(const NfcSource.reader('ACR122U').toFilter(),
        equals(const CcidSourceFilter.reader('ACR122U')));
  });

  test('isAvailable() delegates to the underlying NfcHub', () async {
    final hub = _FakeNfcHub()..availableReturn = false;
    final reader = NfcHubReader.forTesting(hub);
    expect(await reader.isAvailable(), isFalse);
    hub.availableReturn = true;
    expect(await reader.isAvailable(), isTrue);
  });

  test('connectionState() delegates to the underlying NfcHub', () {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final stream = reader.connectionState();
    expect(hub.connectionStateCalls, 1);
    expect(stream, isA<Stream<NfcConnectionState>>());
  });

  test('openNfcSettings() delegates to the underlying NfcHub', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    await reader.openNfcSettings();
    expect(hub.openNfcSettingsCalls, 1);
  });
}
