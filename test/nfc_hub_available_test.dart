import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';

/// A manager whose getNfcState() returns a scripted value. Everything else is
/// inherited.
class _FakeManager extends AndroidNfcManager {
  _FakeManager()
      : super(
          methodChannel: const MethodChannel('nfc_hub'),
          eventChannel: const EventChannel('nfc_hub/events'),
        );

  NfcState nfcState = NfcState.disabled;

  @override
  Future<NfcState> getNfcState() async => nfcState;
}

/// A platform whose listReaders() returns a scripted list and which FAILS the
/// test if connect() is ever called (isAvailable must not start the poll loop).
class _FakePlatform extends NfcHubPlatform {
  List<String> readers = [];

  @override
  Future<List<String>> listReaders() async => List.of(readers);

  @override
  Future<ReaderCard> connect(String reader) async =>
      throw StateError('connect() must not be called by isAvailable()');

  @override
  Future<String?> transceive(String reader, String capdu) async =>
      throw StateError('transceive() must not be called by isAvailable()');

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeManager manager;
  late _FakePlatform platform;

  setUp(() {
    manager = _FakeManager();
    platform = _FakePlatform();
    NfcHubPlatform.instance = platform;
  });

  NfcHub build() => NfcHub(androidNfcManager: manager);

  test('isAvailable() is true when built-in NFC is enabled', () async {
    manager.nfcState = NfcState.enabled;
    platform.readers = [];
    expect(await build().isAvailable(), isTrue);
  });

  test('isAvailable() is true when a reader is attached even if NFC is off',
      () async {
    manager.nfcState = NfcState.disabled;
    platform.readers = ['ACS ACR122U'];
    expect(await build().isAvailable(), isTrue);
  });

  test('isAvailable() is false when NFC is off and no reader is attached',
      () async {
    manager.nfcState = NfcState.disabled;
    platform.readers = [];
    expect(await build().isAvailable(), isFalse);
  });

  test('isAvailable() is false when there is no NFC hardware and no reader',
      () async {
    manager.nfcState = NfcState.noHardware;
    platform.readers = [];
    expect(await build().isAvailable(), isFalse);
  });
}
