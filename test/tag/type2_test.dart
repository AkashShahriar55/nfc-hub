import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/platform_interface.dart';
import 'package:convert/convert.dart';
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

  test('readTagInfo() returns UID and the parsed Capability Container',
      () async {
    CcidPlatform.instance = _FakeCcidPlatform({
      'FFCA000000': '${hex.encode([0x04, 0x01, 0x02, 0x03])}9000',
      'FFB0000304': 'E11006009000',
    });
    final tag = Type2Tag(CcidCard('fake-reader'));

    final info = await tag.readTagInfo();

    expect(info.uid, equals([0x04, 0x01, 0x02, 0x03]));
    expect(info.capabilityContainer, isNotNull);
    expect(info.capabilityContainer!.isNdefFormatted, isTrue);
  });
}
