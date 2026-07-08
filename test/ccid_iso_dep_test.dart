import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
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
}
