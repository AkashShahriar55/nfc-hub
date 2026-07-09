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
    if (!responses.containsKey(capdu)) {
      throw Exception('No fake response configured for capdu: $capdu');
    }
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

  test('authenticateWithDefaultKeys() succeeds on the first working default key',
      () async {
    final fake = _FakeCcidPlatform({
      'FF82000006FFFFFFFFFFFF': '9000',
      'FF860000050100006000': '9000',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    await tag.authenticateWithDefaultKeys(0);

    expect(fake.requestedCapdus, contains('FF82000006FFFFFFFFFFFF'));
    expect(fake.requestedCapdus, contains('FF860000050100006000'));
  });

  test('authenticateWithDefaultKeys() throws MifareAuthException when every '
      'default key fails', () async {
    final fake = _FakeCcidPlatform({
      'FF82000006FFFFFFFFFFFF': '6300',
      'FF82000006A0A1A2A3A4A5': '6300',
      'FF82000006D3F7D3F7D3F7': '6300',
      'FF82000006000000000000': '6300',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    expect(
      () => tag.authenticateWithDefaultKeys(0),
      throwsA(isA<MifareAuthException>()),
    );
  });

  test('readBlock() sends a READ BINARY APDU with the block number in P2 '
      'and returns the decoded data', () async {
    final fake = _FakeCcidPlatform({'FFB0000110': '${'AA' * 16}9000'});
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    final data = await tag.readBlock(1);

    expect(data, equals(List.filled(16, 0xAA)));
  });

  test('readSector() reads all 4 blocks of the sector', () async {
    final fake = _FakeCcidPlatform({
      'FFB0000410': '${'00' * 16}9000',
      'FFB0000510': '${'01' * 16}9000',
      'FFB0000610': '${'02' * 16}9000',
      'FFB0000710': '${'03' * 16}9000',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    final blocks = await tag.readSector(1);

    expect(blocks, hasLength(4));
    expect(blocks[0], equals(List.filled(16, 0x00)));
    expect(blocks[3], equals(List.filled(16, 0x03)));
  });

  test('readTagInfo() resolves the family from a real PN532 poll', () async {
    final fake = _FakeCcidPlatform({
      'FF00000004D44A0100': 'D54B01010044080704010203040506' '9000',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    final info = await tag.readTagInfo();

    expect(info.technology, equals('MIFARE Classic 1K'));
    expect(info.sak, equals(0x08));
    expect(info.uid, equals([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]));
  });
}
