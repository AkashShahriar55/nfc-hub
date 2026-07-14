import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;
  final List<String> requestedCapdus = [];

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
    return responses[capdu];
  }

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

class _SequencedFakeCcidPlatform extends CcidPlatform {
  final List<String?> responses;
  final List<String> requestedCapdus = [];
  int _index = 0;

  _SequencedFakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
    if (_index >= responses.length) {
      throw Exception('No more fake responses configured (requested $capdu)');
    }
    return responses[_index++];
  }

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

  test('selectApplication() sends a SELECT-by-name APDU with the AID as Lc/data',
      () async {
    // AID 'D2760000850101' is 7 bytes (14 hex chars), so Lc = 07.
    final fake = _FakeCcidPlatform({'00A4040007D2760000850101': '9000'});
    CcidPlatform.instance = fake;
    final tag = IsoDepTag(CcidCard('fake-reader'));

    final response = await tag.selectApplication('D2760000850101');

    expect(response, equals('9000'));
    expect(
      fake.requestedCapdus,
      contains('00A4040007D2760000850101'),
    );
  });

  test('transceive() passes the APDU straight through to the card', () async {
    final fake = _FakeCcidPlatform({'00B0000000': 'AABB9000'});
    CcidPlatform.instance = fake;
    final tag = IsoDepTag(CcidCard('fake-reader'));

    final response = await tag.transceive('00B0000000');

    expect(response, equals('AABB9000'));
  });

  group('readDesfireVersion', () {
    test('parses the 3-frame GetVersion exchange (real example from ACS '
        'ACR122U API documentation)', () async {
      final fake = _SequencedFakeCcidPlatform([
        'AF04010100021805',
        'AF04010100061805',
        '0004525A19B21B808E36544D402604',
      ]);
      CcidPlatform.instance = fake;
      final tag = IsoDepTag(CcidCard('fake-reader'));

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
