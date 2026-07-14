import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async =>
      responses[capdu];

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  tearDown(() {
    CcidPlatform.instance = null;
  });

  test('transceive() passes the APDU straight through to the card',
      () async {
    CcidPlatform.instance = _FakeCcidPlatform({'00B0000000': 'AABB9000'});
    final tag = TypeBTag(CcidCard('fake-reader'), Uint8List(12));

    final response = await tag.transceive('00B0000000');

    expect(response, equals('AABB9000'));
  });

  test('stores the ATQB it was constructed with', () {
    final atqb = Uint8List.fromList(List.filled(12, 0x11));
    final tag = TypeBTag(CcidCard('fake-reader'), atqb);

    expect(tag.atqb, equals(atqb));
  });

  test('readTagInfo() extracts the PUPI from ATQB', () async {
    final atqb = Uint8List.fromList(
        [0x50, 0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0, 0, 0]);
    final tag = TypeBTag(CcidCard('fake-reader'), atqb);

    final info = await tag.readTagInfo();

    expect(info.uid, equals([0x11, 0x22, 0x33, 0x44]));
    expect(info.technology, equals('ISO14443-B'));
  });
}
