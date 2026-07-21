import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('nfc_hub');
  const event = EventChannel('nfc_hub/events');
  final log = <MethodCall>[];
  MockStreamHandlerEventSink? sink;

  setUp(() {
    log.clear();
    sink = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      log.add(call);
      switch (call.method) {
        case 'nfcTransceive':
          return Uint8List.fromList([0x90, 0x00]);
        case 'nfcMifareReadBlock':
          return Uint8List.fromList(List.filled(16, 0xAB));
        case 'getNfcState':
          return 'enabled';
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      event,
      MockStreamHandler.inline(
        onListen: (args, events) => sink = events,
      ),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(event, null);
    log.clear();
  });

  test('transceive forwards handle/tech/data and returns the response bytes',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    final r = await m.transceive(
        7, 'IsoDep', Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]));
    expect(r, Uint8List.fromList([0x90, 0x00]));
    expect(log.single.method, 'nfcTransceive');
    final args = log.single.arguments as Map;
    expect(args['handle'], 7);
    expect(args['tech'], 'IsoDep');
    expect(args['data'], Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]));
  });

  test(
      'transceive normalizes a List<int> response (not just a Uint8List) '
      'into a Uint8List', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      log.add(call);
      // Simulate a Kotlin side that returns a generic int list (e.g. via
      // byteArray.toList()) rather than a native ByteArray. invokeMethod's
      // own internal generic cast must not choke on this before _bytes()
      // gets a chance to normalize it.
      return <int>[0x6F, 0x00];
    });
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    final r = await m.transceive(
        7, 'IsoDep', Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]));
    expect(r, isA<Uint8List>());
    expect(r, Uint8List.fromList([0x6F, 0x00]));
  });

  test('transceive throws a clear error when the platform returns null',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async => null);
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await expectLater(
      () => m.transceive(7, 'IsoDep', Uint8List.fromList([0x00])),
      throwsA(isA<StateError>()),
    );
  });

  test('mifareAuthenticate forwards handle/sector/keyA/key', () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await m.mifareAuthenticate(
        3, 2, true, Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]));
    expect(log.single.method, 'nfcMifareAuth');
    final args = log.single.arguments as Map;
    expect(args['handle'], 3);
    expect(args['sector'], 2);
    expect(args['keyA'], true);
    expect(args['key'],
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]));
  });

  test('mifareReadBlock forwards handle/block and returns the block bytes',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    final r = await m.mifareReadBlock(3, 8);
    expect(r, Uint8List.fromList(List.filled(16, 0xAB)));
    expect(log.single.method, 'nfcMifareReadBlock');
    final args = log.single.arguments as Map;
    expect(args['handle'], 3);
    expect(args['block'], 8);
  });

  test(
      'mifareReadBlock normalizes a List<int> response into a Uint8List',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      log.add(call);
      return List<int>.filled(16, 0xCD);
    });
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    final r = await m.mifareReadBlock(3, 8);
    expect(r, isA<Uint8List>());
    expect(r, Uint8List.fromList(List.filled(16, 0xCD)));
  });

  test('startReaderMode/stopReaderMode call the expected methods', () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await m.startReaderMode();
    await m.stopReaderMode();
    expect(log.map((c) => c.method),
        ['nfcStartReaderMode', 'nfcStopReaderMode']);
  });

  test('openNfcSettings calls the expected method', () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await m.openNfcSettings();
    expect(log.single.method, 'openNfcSettings');
  });

  test('getNfcState decodes the string into the enum', () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    expect(await m.getNfcState(), NfcState.enabled);
    expect(log.single.method, 'getNfcState');
  });

  test('getNfcState decodes disabled and noHardware', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async => 'disabled');
    final m1 = AndroidNfcManager();
    addTearDown(m1.dispose);
    expect(await m1.getNfcState(), NfcState.disabled);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async => 'noHardware');
    final m2 = AndroidNfcManager();
    addTearDown(m2.dispose);
    expect(await m2.getNfcState(), NfcState.noHardware);
  });

  test('tagDiscovered event decodes into an NfcTagDiscovery with all fields',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final future = m.discoveries.first;
    sink!.success({
      'type': 'tagDiscovered',
      'handle': 42,
      'techList': ['IsoDep', 'MifareClassic'],
      'uid': [0x01, 0x02, 0x03, 0x04],
      'atqa': [0x00, 0x04],
      'sak': 0x08,
      'atqb': [0x50, 0x0F, 0x00, 0x00],
      'idm': [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
      'pmm': [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
      'historicalBytes': [0xAA, 0xBB],
    });

    final discovery = await future;
    expect(discovery.handle, 42);
    expect(discovery.techList, ['IsoDep', 'MifareClassic']);
    expect(discovery.uid, Uint8List.fromList([0x01, 0x02, 0x03, 0x04]));
    expect(discovery.atqa, Uint8List.fromList([0x00, 0x04]));
    expect(discovery.sak, 0x08);
    expect(discovery.atqb, Uint8List.fromList([0x50, 0x0F, 0x00, 0x00]));
    expect(discovery.idm,
        Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]));
    expect(discovery.pmm,
        Uint8List.fromList([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]));
    expect(discovery.historicalBytes, Uint8List.fromList([0xAA, 0xBB]));
  });

  test('tagDiscovered event with only required fields leaves optionals null',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final future = m.discoveries.first;
    sink!.success({
      'type': 'tagDiscovered',
      'handle': 5,
      'techList': ['NfcA'],
      'uid': [0xDE, 0xAD, 0xBE, 0xEF],
    });

    final discovery = await future;
    expect(discovery.handle, 5);
    expect(discovery.techList, ['NfcA']);
    expect(discovery.uid, Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]));
    expect(discovery.atqa, isNull);
    expect(discovery.sak, isNull);
    expect(discovery.atqb, isNull);
    expect(discovery.idm, isNull);
    expect(discovery.pmm, isNull);
    expect(discovery.historicalBytes, isNull);
  });

  test('byte fields arriving as List<int> normalize to Uint8List', () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final future = m.discoveries.first;
    // Send uid as a plain (non-typed) List<int>, as StandardMethodCodec
    // would if the platform side encoded it as an int32 list or similar.
    sink!.success({
      'type': 'tagDiscovered',
      'handle': 1,
      'techList': <String>['NfcA'],
      'uid': <int>[1, 2, 3],
    });

    final discovery = await future;
    expect(discovery.uid, isA<Uint8List>());
    expect(discovery.uid, Uint8List.fromList([1, 2, 3]));
  });

  test('nfcStateChanged event surfaces the decoded state on nfcStateChanges',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final future = m.nfcStateChanges.first;
    sink!.success({'type': 'nfcStateChanged', 'state': 'disabled'});

    expect(await future, NfcState.disabled);
  });

  test(
      'a malformed tagDiscovered event surfaces as an error on discoveries '
      'and the underlying subscription survives to deliver the next event',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final errors = <Object>[];
    final sub =
        m.discoveries.listen((_) {}, onError: (Object e) => errors.add(e));
    addTearDown(sub.cancel);

    // Missing `handle` -- decoding throws synchronously inside _onEvent.
    sink!.success({
      'type': 'tagDiscovered',
      'techList': ['IsoDep'],
      'uid': [0x01],
    });
    await pumpEventQueue();
    expect(errors, hasLength(1));

    // The single underlying subscription must survive: a subsequent
    // well-formed event is still delivered.
    final future = m.discoveries.first;
    sink!.success({
      'type': 'tagDiscovered',
      'handle': 99,
      'techList': ['IsoDep'],
      'uid': [0x02],
    });
    final discovery = await future;
    expect(discovery.handle, 99);
  });

  test(
      'a malformed event whose type cannot even be read fans out an error '
      'to both streams', () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final discoveryErrors = <Object>[];
    final stateErrors = <Object>[];
    addTearDown(m.discoveries
        .listen((_) {}, onError: (Object e) => discoveryErrors.add(e))
        .cancel);
    addTearDown(m.nfcStateChanges
        .listen((_) {}, onError: (Object e) => stateErrors.add(e))
        .cancel);

    // Not even a Map -- the `event as Map` cast throws before `type` can be
    // read, so this must fan out like _onEventError does.
    sink!.success('not a map');
    await pumpEventQueue();

    expect(discoveryErrors, hasLength(1));
    expect(stateErrors, hasLength(1));

    // The underlying subscription must still survive this too.
    final future = m.discoveries.first;
    sink!.success({
      'type': 'tagDiscovered',
      'handle': 7,
      'techList': ['NfcA'],
      'uid': [0x01],
    });
    expect((await future).handle, 7);
  });

  test('a single event-channel subscription fans out to both streams',
      () async {
    final m = AndroidNfcManager();
    addTearDown(m.dispose);
    await pumpEventQueue();

    final discoveryFuture = m.discoveries.first;
    final stateFuture = m.nfcStateChanges.first;

    sink!.success({
      'type': 'tagDiscovered',
      'handle': 1,
      'techList': ['NfcA'],
      'uid': [0x01],
    });
    sink!.success({'type': 'nfcStateChanged', 'state': 'enabled'});

    expect((await discoveryFuture).handle, 1);
    expect(await stateFuture, NfcState.enabled);
  });
}
