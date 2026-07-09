import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:convert/convert.dart';
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

  const idmHex = 'AABBCCDDEE001122';
  // idm is read via the standard PC/SC Get UID pseudo-APDU, which returns
  // the FeliCa IDm on ACR-family readers (ACS ACR122U NFC Reader API,
  // section 7.3, "The NFC ID can be obtained by using the APDU
  // FF CA 00 00 00").
  const uidCapdu = 'FFCA000000';
  const uidResponse = '${idmHex}9000';

  test('idm reads the card via Get UID and caches the result', () async {
    final fake = _FakeCcidPlatform({uidCapdu: uidResponse});
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final idm = await tag.idm;
    final idmAgain = await tag.idm;

    expect(idm, equals([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x11, 0x22]));
    expect(idmAgain, equals(idm));
    expect(
      fake.requestedCapdus.where((c) => c == uidCapdu),
      hasLength(1),
      reason: 'the second idm access should use the cached value, not read '
          'again',
    );
  });

  test('pmm polls the card and returns the 8-byte PMm, cached', () async {
    // Polling command (00 FF FF 00 00, 5 bytes) framed to 6 bytes (leading
    // length byte 06), wrapped in D4 40 01 -> 9-byte payload -> Lc=09.
    const pollCapdu = 'FF00000009D440010600FFFF0000';
    const pmmHex = '0135428282468CFF';
    // Response: D5 41 00 (InDataExchange success) + FeliCa response frame
    // (18 bytes: len=12, respCode=01, idm(8), pmm(8)).
    const pollResponse = 'D541001201$idmHex${pmmHex}9000';
    final fake = _FakeCcidPlatform({pollCapdu: pollResponse});
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final pmm = await tag.pmm;
    final pmmAgain = await tag.pmm;

    expect(pmm, equals(hex.decode(pmmHex)));
    expect(pmmAgain, equals(pmm));
    expect(
      fake.requestedCapdus.where((c) => c == pollCapdu),
      hasLength(1),
      reason: 'the second pmm access should use the cached value, not poll '
          'again',
    );
  });

  test(
      'readWithoutEncryption() wraps the FeliCa frame in a PN532 '
      'InDataExchange command and parses a successful response', () async {
    // Read command frame (15 bytes): cmd=06, idm(8), numServices=01,
    // serviceCode LE (0F22 for 0x220F), numBlocks=01,
    // blockListElement(80,00) -> length-prefixed to 16 bytes (10 hex),
    // then wrapped in D4 40 01 (PN532 InDataExchange, target #1) -> 19
    // bytes (13 hex) total payload sent via
    // FF 00 00 00 <Lc> D4 40 01 <frame>. Byte layout verified against ACS's
    // ACR122U NFC Reader API, section 7.3 worked example.
    const readCapdu =
        'FF00000013D440011006AABBCCDDEE001122010F22018000';
    // Response: D5 41 00 (InDataExchange success) + FeliCa response frame
    // (29 bytes): len=1D, respCode=07, idm(8), SF1=00, SF2=00, numBlocks=01,
    // block(16 bytes of 0xAA).
    const readResponse = 'D541001D07AABBCCDDEE001122000001'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '9000';
    final fake = _FakeCcidPlatform({
      uidCapdu: uidResponse,
      readCapdu: readResponse,
    });
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final result = await tag.readWithoutEncryption(0x220F, [0]);

    expect(result.isSuccess, isTrue);
    expect(result.blocks, hasLength(1));
    expect(result.blocks[0], equals(List.filled(16, 0xAA)));
  });

  test('readWithoutEncryption() throws when InDataExchange reports a '
      'non-zero status', () async {
    const readCapdu =
        'FF00000013D440011006AABBCCDDEE001122010F22018000';
    // D5 41 <non-zero status> — InDataExchange itself failed (e.g. target
    // lost), no FeliCa response frame follows.
    const readResponse = 'D5417F9000';
    final fake = _FakeCcidPlatform({
      uidCapdu: uidResponse,
      readCapdu: readResponse,
    });
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    expect(
      () => tag.readWithoutEncryption(0x220F, [0]),
      throwsException,
    );
  });

  test('requestSystemCodes() enumerates every system on the card', () async {
    const uidResponseLocal = '${idmHex}9000';
    // Request System Code command (0C + idm(8), 9 bytes) framed to 10 bytes
    // (leading length byte 0A), wrapped in D4 40 01 -> 13-byte payload ->
    // Lc=0D.
    const requestCapdu = 'FF0000000DD440010A0CAABBCCDDEE001122';
    // Response frame: len=0F (15 bytes: len+respCode+idm(8)+numSystems+
    // 2 system codes), respCode=0D, idm(8), numSystems=02,
    // systemCode0=0003, systemCode1=90E3.
    const requestResponse = 'D541000F0D${idmHex}02000390E39000';
    final fake = _FakeCcidPlatform({
      uidCapdu: uidResponseLocal,
      requestCapdu: requestResponse,
    });
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final systemCodes = await tag.requestSystemCodes();

    expect(systemCodes, equals([0x0003, 0x90E3]));
  });
}
