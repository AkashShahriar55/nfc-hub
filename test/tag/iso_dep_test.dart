import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [IsoDepTransport] mapping request-hex -> response-hex, the same
/// idiom the migrated driver tests (type2_test.dart, felica_test.dart) use
/// for their fake transports.
class _FakeIsoDepTransport implements IsoDepTransport {
  final Map<String, String> responses;
  final List<String> requestedCapdus = [];

  _FakeIsoDepTransport(this.responses);

  @override
  Future<Uint8List> get uid async => Uint8List(0);

  @override
  Uint8List? get historicalBytes => null;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final capdu = hex.encode(apdu).toUpperCase();
    requestedCapdus.add(capdu);
    final response = responses[capdu];
    if (response == null) {
      throw Exception('No fake response configured for capdu: $capdu');
    }
    return Uint8List.fromList(hex.decode(response));
  }
}

/// Fake [IsoDepTransport] that returns each response in [responses] in
/// order, regardless of the request bytes -- needed because DESFire's
/// GetVersion exchange sends the same continuation APDU ('AF') twice with
/// two different expected responses.
class _SequencedFakeIsoDepTransport implements IsoDepTransport {
  final List<String> responses;
  final List<String> requestedCapdus = [];
  int _index = 0;

  _SequencedFakeIsoDepTransport(this.responses);

  @override
  Future<Uint8List> get uid async => Uint8List(0);

  @override
  Uint8List? get historicalBytes => null;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final capdu = hex.encode(apdu).toUpperCase();
    requestedCapdus.add(capdu);
    if (_index >= responses.length) {
      throw Exception('No more fake responses configured (requested $capdu)');
    }
    return Uint8List.fromList(hex.decode(responses[_index++]));
  }
}

void main() {
  test('selectApplication() sends a SELECT-by-name APDU with the AID as Lc/data',
      () async {
    // AID 'D2760000850101' is 7 bytes (14 hex chars), so Lc = 07.
    final fake = _FakeIsoDepTransport({'00A4040007D2760000850101': '9000'});
    final tag = IsoDepTag(fake);

    final response = await tag.selectApplication('D2760000850101');

    expect(response, equals('9000'));
    expect(
      fake.requestedCapdus,
      contains('00A4040007D2760000850101'),
    );
  });

  test('transceive() passes the APDU straight through to the transport',
      () async {
    final fake = _FakeIsoDepTransport({'00B0000000': 'AABB9000'});
    final tag = IsoDepTag(fake);

    final response = await tag.transceive('00B0000000');

    expect(response, equals('AABB9000'));
  });

  group('readDesfireVersion', () {
    test('parses the 3-frame GetVersion exchange (real example from ACS '
        'ACR122U API documentation)', () async {
      final fake = _SequencedFakeIsoDepTransport([
        'AF04010100021805',
        'AF04010100061805',
        '0004525A19B21B808E36544D402604',
      ]);
      final tag = IsoDepTag(fake);

      final version = await tag.readDesfireVersion();

      expect(version.hardwareVendorId, equals(0x04));
      expect(version.hardwareType, equals(0x01));
      expect(version.hardwareSubtype, equals(0x01));
      expect(version.hardwareMajor, equals(0x00));
      expect(version.hardwareMinor, equals(0x02));
      expect(version.hardwareStorageSize, equals(0x18));
      expect(version.hardwareProtocol, equals(0x05));
      expect(version.softwareMinor, equals(0x06));
      expect(version.uid, equals([0x04, 0x52, 0x5A, 0x19, 0xB2, 0x1B, 0x80]));
      expect(version.batch, equals([0x8E, 0x36, 0x54, 0x4D, 0x40]));
      expect(version.productionWeek, equals(0x26));
      expect(version.productionYear, equals(0x04));
      expect(fake.requestedCapdus, equals(['60', 'AF', 'AF']));
    });
  });
}
