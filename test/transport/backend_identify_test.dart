import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';

class _FakeType2Transport implements Type2Transport {
  @override
  Future<Uint8List> readUid() async => Uint8List.fromList([4, 1, 2, 3]);
  @override
  Future<Uint8List> readCapabilityContainer() async =>
      Uint8List.fromList([0xE1, 0x10, 0x6D, 0x00]);
  @override
  Future<Uint8List> readPages(int startPage) async => Uint8List(16);
  @override
  Future<Uint8List?> getVersion() async => null;
}

class _FakeMifareClassicTransport implements MifareClassicTransport {
  @override
  Uint8List get uid => Uint8List.fromList([4, 1, 2, 3]);
  @override
  Uint8List get atqa => Uint8List.fromList([0, 4]);
  @override
  int get sak => 0x08;
  @override
  Future<void> authenticate(int s, MifareKeyType t, Uint8List k) async {}
  @override
  Future<Uint8List> readBlock(int b) async => Uint8List(16);
}

class _FakeNfcFTransport implements NfcFTransport {
  @override
  Future<Uint8List> get idm async =>
      Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
  @override
  Future<Uint8List> get pmm async =>
      Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
  @override
  Future<Uint8List> transceive(Uint8List felicaFrame) async => Uint8List(0);
}

class _FakeIsoDepTransport implements IsoDepTransport {
  @override
  Future<Uint8List> get uid async => Uint8List.fromList([4, 1, 2, 3]);
  @override
  Uint8List? get historicalBytes => null;
  @override
  Future<Uint8List> transceive(Uint8List apdu) async => Uint8List(0);
}

class _FakeNfcBTransport implements NfcBTransport {
  @override
  Uint8List get pupi => Uint8List.fromList([1, 2, 3, 4]);
  @override
  Uint8List get atqb =>
      Uint8List.fromList([0x50, 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0]);
  @override
  Future<Uint8List> transceive(Uint8List apdu) async => Uint8List(0);
}

class _FakeBackend implements TransportBackend {
  @override
  Type2Transport type2() => _FakeType2Transport();
  @override
  Future<MifareClassicTransport> mifareClassic() async =>
      _FakeMifareClassicTransport();
  @override
  NfcFTransport nfcF() => _FakeNfcFTransport();
  @override
  Future<IsoDepTransport> isoDep() async => _FakeIsoDepTransport();
  @override
  Future<NfcBTransport?> nfcB() async => _FakeNfcBTransport();
}

class _FakeBackendNoTypeB implements TransportBackend {
  @override
  Type2Transport type2() => _FakeType2Transport();
  @override
  Future<MifareClassicTransport> mifareClassic() async =>
      _FakeMifareClassicTransport();
  @override
  NfcFTransport nfcF() => _FakeNfcFTransport();
  @override
  Future<IsoDepTransport> isoDep() async => _FakeIsoDepTransport();
  @override
  Future<NfcBTransport?> nfcB() async => null;
}

void main() {
  test('hint type2 -> Type2Tag, no probing', () async {
    final driver =
        await identifyFromBackend(_FakeBackend(), hint: TagTechHint.type2);
    expect(driver, isA<Type2Tag>());
  });

  test('hint mifareClassic -> MifareClassicTag', () async {
    final driver = await identifyFromBackend(_FakeBackend(),
        hint: TagTechHint.mifareClassic);
    expect(driver, isA<MifareClassicTag>());
  });

  test('hint felica -> FelicaTag', () async {
    final driver =
        await identifyFromBackend(_FakeBackend(), hint: TagTechHint.felica);
    expect(driver, isA<FelicaTag>());
  });

  test('hint isoDep -> IsoDepTag', () async {
    final driver =
        await identifyFromBackend(_FakeBackend(), hint: TagTechHint.isoDep);
    expect(driver, isA<IsoDepTag>());
  });

  test('hint typeB -> TypeBTag', () async {
    final driver =
        await identifyFromBackend(_FakeBackend(), hint: TagTechHint.typeB);
    expect(driver, isA<TypeBTag>());
  });

  test('hint typeB throws UnrecognizedTagException when no Type B target',
      () async {
    expect(
      () => identifyFromBackend(_FakeBackendNoTypeB(), hint: TagTechHint.typeB),
      throwsA(isA<UnrecognizedTagException>()),
    );
  });

  test('hint carries the atr through to the driver', () async {
    final atr = Uint8List.fromList([0x3B, 0x8F]);
    final driver = await identifyFromBackend(_FakeBackend(),
        hint: TagTechHint.mifareClassic, atr: atr);
    final info = await driver.readTagInfo();
    expect(info.atr, atr);
  });

  test('null hint requires a CcidTransportBackend', () async {
    expect(
      () => identifyFromBackend(_FakeBackend()),
      throwsA(isA<ArgumentError>()),
    );
  });
}
