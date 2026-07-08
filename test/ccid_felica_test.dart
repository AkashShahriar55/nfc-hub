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

  // Polling frame (6 bytes): cmd=00, sysCode=FFFF, requestCode=00,
  // timeSlot=00. Wrapped as FF 00 00 00 <Lc=06> <length-prefixed frame>
  // where the frame's own length byte (06) counts itself + the 5 bytes
  // after it.
  const pollCapdu = 'FF000000060600FFFF0000';
  const idmHex = 'AABBCCDDEE001122';
  // Response frame (10 bytes): len=0A, respCode=01, idm(8 bytes).
  const pollResponse = '0A01${idmHex}9000';

  test('idm polls the card and caches the result', () async {
    final fake = _FakeCcidPlatform({pollCapdu: pollResponse});
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final idm = await tag.idm;
    final idmAgain = await tag.idm;

    expect(idm, equals([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x11, 0x22]));
    expect(idmAgain, equals(idm));
    expect(
      fake.requestedCapdus.where((c) => c == pollCapdu),
      hasLength(1),
      reason: 'the second idm access should use the cached value, not poll '
          'again',
    );
  });

  test(
      'readWithoutEncryption() builds the FeliCa Read Without Encryption '
      'frame and parses a successful response', () async {
    // Read command frame (15 bytes): cmd=06, idm(8), numServices=01,
    // serviceCode LE (0F22 for 0x220F), numBlocks=01,
    // blockListElement(80,00). Wrapped as FF 00 00 00 <Lc=10>
    // <length-prefixed frame> (frame's own length byte = 10 = 15+1).
    const readCapdu = 'FF000000101006AABBCCDDEE001122010F22018000';
    // Response frame (29 bytes): len=1D, respCode=07, idm(8), SF1=00,
    // SF2=00, numBlocks=01, block(16 bytes of 0xAA).
    const readResponse = '1D07AABBCCDDEE001122000001'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '9000';
    final fake = _FakeCcidPlatform({
      pollCapdu: pollResponse,
      readCapdu: readResponse,
    });
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final result = await tag.readWithoutEncryption(0x220F, [0]);

    expect(result.isSuccess, isTrue);
    expect(result.blocks, hasLength(1));
    expect(result.blocks[0], equals(List.filled(16, 0xAA)));
  });
}
