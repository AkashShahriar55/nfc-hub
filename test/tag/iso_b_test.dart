import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNfcBTransport implements NfcBTransport {
  @override
  final Uint8List atqb;
  @override
  final Uint8List pupi;
  final Map<String, String> responses;

  _FakeNfcBTransport(this.atqb, this.pupi, [this.responses = const {}]);

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final capdu = hex.encode(apdu).toUpperCase();
    final response = responses[capdu];
    if (response == null) {
      throw Exception('No fake response configured for capdu: $capdu');
    }
    return Uint8List.fromList(hex.decode(response));
  }
}

void main() {
  test('transceive() passes the APDU straight through to the card',
      () async {
    final tag = TypeBTag(_FakeNfcBTransport(
      Uint8List(12),
      Uint8List(4),
      {'00B0000000': 'AABB9000'},
    ));

    final response = await tag.transceive('00B0000000');

    expect(response, equals('AABB9000'));
  });

  test('stores the ATQB it was constructed with', () {
    final atqb = Uint8List.fromList(List.filled(12, 0x11));
    final tag = TypeBTag(_FakeNfcBTransport(atqb, Uint8List(4)));

    expect(tag.atqb, equals(atqb));
  });

  test('readTagInfo() extracts the PUPI from ATQB', () async {
    final atqb = Uint8List.fromList(
        [0x50, 0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0, 0, 0]);
    final pupi = Uint8List.fromList([0x11, 0x22, 0x33, 0x44]);
    final tag = TypeBTag(_FakeNfcBTransport(atqb, pupi));

    final info = await tag.readTagInfo();

    expect(info.uid, equals([0x11, 0x22, 0x33, 0x44]));
    expect(info.technology, equals('ISO14443-B'));
  });
}
