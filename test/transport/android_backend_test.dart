import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';
import 'package:nfc_hub/src/transport/android_backend.dart';

/// Records every transceive/mifareAuthenticate/mifareReadBlock call and
/// replies from scripted responses/errors, WITHOUT touching any real
/// platform channel.
class _FakeAndroidNfcManager extends AndroidNfcManager {
  _FakeAndroidNfcManager()
      : super(
          methodChannel: const MethodChannel('nfc_hub'),
          eventChannel: const EventChannel('nfc_hub/events'),
        );

  final transceiveCalls = <(int, String, Uint8List)>[];
  Uint8List? transceiveResponse;
  Object? transceiveError;

  final mifareAuthCalls = <(int, int, bool, Uint8List)>[];
  Object? mifareAuthError;

  final mifareReadBlockCalls = <int>[];
  Uint8List? mifareReadBlockResponse;
  Object? mifareReadBlockError;

  @override
  Future<Uint8List> transceive(int handle, String tech, Uint8List data) async {
    transceiveCalls.add((handle, tech, data));
    final error = transceiveError;
    if (error != null) throw error;
    return transceiveResponse!;
  }

  @override
  Future<void> mifareAuthenticate(
      int handle, int sector, bool keyA, Uint8List key) async {
    mifareAuthCalls.add((handle, sector, keyA, key));
    final error = mifareAuthError;
    if (error != null) throw error;
  }

  @override
  Future<Uint8List> mifareReadBlock(int handle, int block) async {
    mifareReadBlockCalls.add(block);
    final error = mifareReadBlockError;
    if (error != null) throw error;
    return mifareReadBlockResponse!;
  }
}

NfcTagDiscovery _discovery({
  int handle = 7,
  List<String> techList = const [],
  Uint8List? uid,
  Uint8List? atqa,
  int? sak,
  Uint8List? atqb,
  Uint8List? idm,
  Uint8List? pmm,
  Uint8List? historicalBytes,
}) {
  return NfcTagDiscovery(
    handle: handle,
    techList: techList,
    uid: uid ?? Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC]),
    atqa: atqa,
    sak: sak,
    atqb: atqb,
    idm: idm,
    pmm: pmm,
    historicalBytes: historicalBytes,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Neutralize the real channels the fake manager's superclass constructor
  // wires up (event-channel `listen`), so construction never reaches out to
  // an actual platform.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('nfc_hub'), (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('nfc_hub/events'),
      MockStreamHandler.inline(onListen: (args, events) {}),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nfc_hub'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('nfc_hub/events'), null);
  });

  group('Type2 transport', () {
    test('readUid returns the discovery UID with no transceive call', () async {
      final manager = _FakeAndroidNfcManager();
      final discovery =
          _discovery(uid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]));
      final t = AndroidTransportBackend(manager, discovery).type2();

      final uid = await t.readUid();

      expect(uid, Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]));
      expect(manager.transceiveCalls, isEmpty);
    });

    test(
        'readCapabilityContainer sends 30 03 over NfcA and takes the first 4 bytes',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList(
            List.filled(16, 0xAB)..setRange(0, 4, [0xE1, 0x10, 0x6D, 0x00]));
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      final cc = await t.readCapabilityContainer();

      expect(manager.transceiveCalls.length, 1);
      expect(manager.transceiveCalls.single.$1, 7);
      expect(manager.transceiveCalls.single.$2, 'NfcA');
      expect(
          manager.transceiveCalls.single.$3, Uint8List.fromList([0x30, 0x03]));
      expect(cc, Uint8List.fromList([0xE1, 0x10, 0x6D, 0x00]));
    });

    test('readPages(4) sends 30 04 over NfcA', () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList(List.filled(16, 0x11));
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      final page = await t.readPages(4);

      expect(manager.transceiveCalls.length, 1);
      expect(manager.transceiveCalls.single.$1, 7);
      expect(manager.transceiveCalls.single.$2, 'NfcA');
      expect(
          manager.transceiveCalls.single.$3, Uint8List.fromList([0x30, 0x04]));
      expect(page.length, 16);
    });

    test('getVersion sends 60 over NfcA and returns the 8-byte response',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList(
            [0x00, 0x04, 0x03, 0x01, 0x01, 0x00, 0x0B, 0x03]);
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      final v = await t.getVersion();

      expect(manager.transceiveCalls.length, 1);
      expect(manager.transceiveCalls.single.$1, 7);
      expect(manager.transceiveCalls.single.$2, 'NfcA');
      expect(manager.transceiveCalls.single.$3, Uint8List.fromList([0x60]));
      expect(v!.length, 8);
    });

    test('getVersion returns null (never throws) when the manager throws',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveError = Exception('NfcA GET_VERSION not supported');
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      final v = await t.getVersion();

      expect(v, isNull);
    });

    test('getVersion returns null when the manager throws TAG_LOST too',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      final v = await t.getVersion();

      expect(v, isNull);
    });

    test('getVersion returns null when the response is not exactly 8 bytes',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList([0x00, 0x04, 0x03]);
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      final v = await t.getVersion();

      expect(v, isNull);
    });

    test('a TAG_LOST platform exception surfaces as TagLostException',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final t = AndroidTransportBackend(manager, _discovery()).type2();

      expect(() => t.readPages(4), throwsA(isA<TagLostException>()));
    });
  });

  group('MifareClassic transport', () {
    test('identity getters return the discovery fields with no transceive call',
        () async {
      final manager = _FakeAndroidNfcManager();
      final discovery = _discovery(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        atqa: Uint8List.fromList([0x00, 0x04]),
        sak: 0x08,
      );
      final t =
          await AndroidTransportBackend(manager, discovery).mifareClassic();

      expect(t.uid, Uint8List.fromList([1, 2, 3, 4]));
      expect(t.atqa, Uint8List.fromList([0x00, 0x04]));
      expect(t.sak, 0x08);
      expect(manager.transceiveCalls, isEmpty);
    });

    test(
        'authenticate(1, keyA, key) calls manager.mifareAuthenticate(h, 1, true, key)',
        () async {
      final manager = _FakeAndroidNfcManager();
      final key = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      final t =
          await AndroidTransportBackend(manager, _discovery()).mifareClassic();

      await t.authenticate(1, MifareKeyType.a, key);

      expect(manager.mifareAuthCalls.length, 1);
      expect(manager.mifareAuthCalls.single.$1, 7);
      expect(manager.mifareAuthCalls.single.$2, 1);
      expect(manager.mifareAuthCalls.single.$3, true);
      expect(manager.mifareAuthCalls.single.$4, key);
    });

    test('authenticate with keyB passes keyA=false', () async {
      final manager = _FakeAndroidNfcManager();
      final key = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      final t =
          await AndroidTransportBackend(manager, _discovery()).mifareClassic();

      await t.authenticate(2, MifareKeyType.b, key);

      expect(manager.mifareAuthCalls.length, 1);
      expect(manager.mifareAuthCalls.single.$1, 7);
      expect(manager.mifareAuthCalls.single.$2, 2);
      expect(manager.mifareAuthCalls.single.$3, false);
      expect(manager.mifareAuthCalls.single.$4, key);
    });

    test(
        'authenticate throws MifareAuthException when the manager rejects the key',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..mifareAuthError = PlatformException(
            code: 'MIFARE_AUTH_FAILED', message: 'auth rejected');
      final t =
          await AndroidTransportBackend(manager, _discovery()).mifareClassic();

      expect(
        () => t.authenticate(
            1, MifareKeyType.a, Uint8List.fromList([0, 0, 0, 0, 0, 0])),
        throwsA(isA<MifareAuthException>()),
      );
    });

    test(
        'authenticate maps a TAG_LOST failure to TagLostException, not MifareAuthException',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..mifareAuthError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final t =
          await AndroidTransportBackend(manager, _discovery()).mifareClassic();

      expect(
        () => t.authenticate(
            1, MifareKeyType.a, Uint8List.fromList([0, 0, 0, 0, 0, 0])),
        throwsA(isA<TagLostException>()),
      );
    });

    test('readBlock(b) calls manager.mifareReadBlock(h, b)', () async {
      final manager = _FakeAndroidNfcManager()
        ..mifareReadBlockResponse = Uint8List.fromList(List.filled(16, 0xCD));
      final t =
          await AndroidTransportBackend(manager, _discovery()).mifareClassic();

      final block = await t.readBlock(5);

      expect(manager.mifareReadBlockCalls, [5]);
      expect(block, Uint8List.fromList(List.filled(16, 0xCD)));
    });

    test('readBlock maps TAG_LOST to TagLostException', () async {
      final manager = _FakeAndroidNfcManager()
        ..mifareReadBlockError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final t =
          await AndroidTransportBackend(manager, _discovery()).mifareClassic();

      expect(() => t.readBlock(5), throwsA(isA<TagLostException>()));
    });
  });

  group('NfcF transport', () {
    test(
        'transceive PREPENDS the length byte before handing off to NfcF '
        '(the Plan 2 regression: no PN532 D4/D5 wrapping)', () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList([0x00]);
      final t = AndroidTransportBackend(manager, _discovery()).nfcF();

      final idm =
          Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
      final frame = Uint8List.fromList([0x0C, ...idm]);

      await t.transceive(frame);

      // 0x0A = 9 (frame.length) + 1.
      expect(manager.transceiveCalls.length, 1);
      expect(manager.transceiveCalls.single.$1, 7);
      expect(manager.transceiveCalls.single.$2, 'NfcF');
      expect(manager.transceiveCalls.single.$3,
          Uint8List.fromList([0x0A, 0x0C, ...idm]));
    });

    test('idm/pmm return the discovery fields with no transceive call',
        () async {
      final manager = _FakeAndroidNfcManager();
      final discovery = _discovery(
        idm: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        pmm: Uint8List.fromList([9, 10, 11, 12, 13, 14, 15, 16]),
      );
      final t = AndroidTransportBackend(manager, discovery).nfcF();

      expect(await t.idm, Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(await t.pmm, Uint8List.fromList([9, 10, 11, 12, 13, 14, 15, 16]));
      expect(manager.transceiveCalls, isEmpty);
    });

    test('a TAG_LOST platform exception surfaces as TagLostException',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final t = AndroidTransportBackend(manager, _discovery()).nfcF();

      expect(() => t.transceive(Uint8List.fromList([0x0C])),
          throwsA(isA<TagLostException>()));
    });
  });

  group('IsoDep transport', () {
    test(
        'transceive sends the APDU unchanged over IsoDep and returns the raw response WITH the SW',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList([0x6A, 0x82]);
      final t = await AndroidTransportBackend(manager, _discovery()).isoDep();

      final apdu = Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]);
      final response = await t.transceive(apdu);

      expect(manager.transceiveCalls.length, 1);
      expect(manager.transceiveCalls.single.$1, 7);
      expect(manager.transceiveCalls.single.$2, 'IsoDep');
      expect(manager.transceiveCalls.single.$3, apdu);
      // NOT stripped: the fake's raw response (a failing SW here) comes
      // back untouched -- DESFire native mode has no SW at all, so this
      // transport must never assume or strip one.
      expect(response, Uint8List.fromList([0x6A, 0x82]));
    });

    test('uid/historicalBytes come from the discovery with no transceive call',
        () async {
      final manager = _FakeAndroidNfcManager();
      final discovery = _discovery(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        historicalBytes: Uint8List.fromList([0x80, 0x31]),
      );
      final t = await AndroidTransportBackend(manager, discovery).isoDep();

      expect(await t.uid, Uint8List.fromList([1, 2, 3, 4]));
      expect(t.historicalBytes, Uint8List.fromList([0x80, 0x31]));
      expect(manager.transceiveCalls, isEmpty);
    });

    test('a TAG_LOST platform exception surfaces as TagLostException',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final t = await AndroidTransportBackend(manager, _discovery()).isoDep();

      expect(() => t.transceive(Uint8List.fromList([0x00])),
          throwsA(isA<TagLostException>()));
    });
  });

  group('NfcB transport', () {
    test('transceive sends the APDU unchanged over NfcB', () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveResponse = Uint8List.fromList([0x90, 0x00]);
      final discovery = _discovery(
          atqb: Uint8List.fromList([
        0x50,
        0x11,
        0x22,
        0x33,
        0x44,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03
      ]));
      final t = await AndroidTransportBackend(manager, discovery).nfcB();
      final apdu = Uint8List.fromList([0x00, 0xA4, 0x04, 0x00]);

      final response = await t!.transceive(apdu);

      expect(manager.transceiveCalls.length, 1);
      expect(manager.transceiveCalls.single.$1, 7);
      expect(manager.transceiveCalls.single.$2, 'NfcB');
      expect(manager.transceiveCalls.single.$3, apdu);
      expect(response, Uint8List.fromList([0x90, 0x00]));
    });

    test('pupi/atqb come from the discovery with no transceive call', () async {
      final manager = _FakeAndroidNfcManager();
      final atqb = Uint8List.fromList([
        0x50,
        0x11,
        0x22,
        0x33,
        0x44,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03
      ]);
      final discovery = _discovery(atqb: atqb);
      final t = await AndroidTransportBackend(manager, discovery).nfcB();

      expect(t!.pupi, Uint8List.fromList([0x11, 0x22, 0x33, 0x44]));
      expect(t.atqb, atqb);
      expect(manager.transceiveCalls, isEmpty);
    });

    test('nfcB() returns null when the discovery has no ATQB', () async {
      final manager = _FakeAndroidNfcManager();
      final t = await AndroidTransportBackend(manager, _discovery()).nfcB();

      expect(t, isNull);
    });

    test('a TAG_LOST platform exception surfaces as TagLostException',
        () async {
      final manager = _FakeAndroidNfcManager()
        ..transceiveError =
            PlatformException(code: 'TAG_LOST', message: 'Tag was lost');
      final discovery = _discovery(
          atqb: Uint8List.fromList([
        0x50,
        0x11,
        0x22,
        0x33,
        0x44,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03
      ]));
      final t = await AndroidTransportBackend(manager, discovery).nfcB();

      expect(() => t!.transceive(Uint8List.fromList([0x00])),
          throwsA(isA<TagLostException>()));
    });
  });
}
