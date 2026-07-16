import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/ccid_backend.dart';

/// Records every C-APDU sent and replies from a scripted map.
class _FakePlatform extends NfcHubPlatform {
  _FakePlatform(this.responses) : super();

  final Map<String, String> responses;
  final List<String> sent = [];

  @override
  Future<List<String>> listReaders() async => ['fake'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}

  @override
  Future<String?> transceive(String reader, String capdu) async {
    sent.add(capdu); // raw, case preserved -- do not uppercase here.
    return responses[capdu.toUpperCase()];
  }
}

void main() {
  late _FakePlatform platform;

  void install(Map<String, String> responses) {
    platform = _FakePlatform(responses);
    NfcHubPlatform.instance = platform;
  }

  tearDown(() => NfcHubPlatform.instance = null);

  group('Type2 transport', () {
    test('readUid sends the PC/SC Get Data pseudo-APDU', () async {
      install({'FFCA000000': '04AABBCCDDEEFF9000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final uid = await t.readUid();

      expect(platform.sent, ['FFCA000000']);
      expect(uid, Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]));
    });

    test('readCapabilityContainer reads 4 bytes at page 3 (Le=04, NOT 10)',
        () async {
      install({'FFB0000304': 'E1106D009000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final cc = await t.readCapabilityContainer();

      expect(platform.sent, ['FFB0000304']);
      expect(cc, Uint8List.fromList([0xE1, 0x10, 0x6D, 0x00]));
    });

    test('readPages sends a 5-byte READ BINARY with P2 = the page number',
        () async {
      // Regression guard: the historical bug here was 'FFB00000${page}10',
      // a 6-byte APDU with P2 stuck at 00, so every page read returned page 0.
      install({'FFB0000410': '${'11' * 16}9000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final page = await t.readPages(4);

      expect(platform.sent, ['FFB0000410']);
      expect(page.length, 16);
    });

    test('getVersion sends the escape-wrapped GET_VERSION and returns 8 bytes',
        () async {
      install({'FF0000000160': '0004030101000B039000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final v = await t.getVersion();

      expect(platform.sent, ['FF0000000160']);
      expect(v!.length, 8);
    });

    test('getVersion returns null (does not throw) when unsupported',
        () async {
      install({'FF0000000160': '6A81'}); // not 9000
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      expect(await t.getVersion(), isNull);
    });
  });

  group('MifareClassic transport', () {
    // ATQA 0400, SAK 08, UID 04AABBCC -- an InListPassiveTarget reply.
    const pollA = 'D54B01010004080404AABBCC9000';

    test('authenticate loads the key then general-authenticates the block',
        () async {
      install({
        'FF00000004D44A0100': pollA,
        'FF82000006FFFFFFFFFFFF': '9000',
        'FF860000050100046000': '9000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();
      platform.sent.clear();

      await t.authenticate(
        1, // sector 1 -> block 4
        MifareKeyType.a,
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
      );

      expect(platform.sent, [
        // Load Key: slot 00, 6-byte key, UPPERCASE hex.
        'FF82000006FFFFFFFFFFFF',
        // General Authenticate: block 04, key A (60), slot 00.
        'FF860000050100046000',
      ]);
    });

    test('readBlock sends READ BINARY with P2 = the block number', () async {
      install({
        'FF00000004D44A0100': pollA,
        'FFB0000410': '${'22' * 16}9000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();
      platform.sent.clear();

      final block = await t.readBlock(4);

      expect(platform.sent, ['FFB0000410']);
      expect(block.length, 16);
    });

    test('identity fields come from the PN532 poll, not the ATR', () async {
      install({'FF00000004D44A0100': pollA});
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();

      expect(t.sak, 0x08);
      expect(t.atqa, Uint8List.fromList([0x00, 0x04]));
      expect(t.uid, Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC]));
    });

    test('authenticate throws MifareAuthException when the key is rejected',
        () async {
      install({
        'FF00000004D44A0100': pollA,
        'FF82000006FFFFFFFFFFFF': '6300', // rejected
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();

      expect(
        () => t.authenticate(0, MifareKeyType.a,
            Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
        throwsA(isA<MifareAuthException>()),
      );
    });

    test('Load Key sends the key as UPPERCASE hex', () async {
      // hex.encode() yields lowercase; the reader expects uppercase here,
      // and the original hardware-validated code calls .toUpperCase().
      // Guard it: without that call the key goes out as 'a0a1a2a3a4a5'.
      install({
        'FF00000004D44A0100': pollA,
        'FF82000006A0A1A2A3A4A5': '9000',
        'FF860000050100006000': '9000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();
      platform.sent.clear();

      await t.authenticate(0, MifareKeyType.a,
          Uint8List.fromList([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]));

      expect(platform.sent.first, 'FF82000006A0A1A2A3A4A5');
      expect(platform.sent.first, isNot(contains('a0a1'))); // not lowercase
    });
  });

  group('NfcF transport', () {
    test('transceive wraps the frame in PN532 InDataExchange and strips D541',
        () async {
      // Request System Code (0x0C) + 8-byte IDm = 9-byte frame.
      // Framed: [0x0A, 0x0C, idm...]  ->  payload D4 40 01 0A 0C <idm>
      // Lc = 3 + 10 = 13 = 0x0D.
      const idm = '0102030405060708';
      const capdu = 'FF0000000DD440010A0C$idm';
      install({capdu: 'D541000D0D${idm}0190E39000'});
      final t = CcidTransportBackend(CcidCard('fake')).nfcF();

      final frame = Uint8List.fromList([
        0x0C, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
      ]);
      final response = await t.transceive(frame);

      expect(platform.sent, [capdu]);
      // The D5 41 00 InDataExchange header is stripped; the raw FeliCa
      // response frame (length byte included) comes back.
      expect(response[0], 0x0D);
      expect(response[1], 0x0D); // Request System Code response code
    });

    test('idm reads via Get UID (the reader returns the FeliCa IDm)',
        () async {
      install({'FFCA000000': '01020304050607089000'});
      final t = CcidTransportBackend(CcidCard('fake')).nfcF();

      expect(await t.idm, Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(platform.sent, ['FFCA000000']);
    });

    // Fixture shared with test/tag/felica_test.dart's "pmm polls the card"
    // test: Polling command (00 FFFF 00 00, 5 bytes) framed to 6 bytes
    // (leading length byte 06), wrapped in D4 40 01 -> 9-byte payload ->
    // Lc=09. PMm is response[10..18] of the InDataExchange-stripped frame.
    const idm = 'AABBCCDDEE001122';
    const pmmHex = '0135428282468CFF';
    const pollCapdu = 'FF00000009D440010600FFFF0000';
    const pollResponse = 'D541001201$idm${pmmHex}9000';
    final pmmBytes = Uint8List.fromList(
        [0x01, 0x35, 0x42, 0x82, 0x82, 0x46, 0x8C, 0xFF]);

    test('pmm sends the FeliCa Polling frame and returns the 8-byte PMm',
        () async {
      install({pollCapdu: pollResponse});
      final t = CcidTransportBackend(CcidCard('fake')).nfcF();

      final pmm = await t.pmm;

      expect(platform.sent, [pollCapdu]);
      expect(pmm, pmmBytes);
    });

    test('pmm is cached -- a second read does not re-send the polling APDU',
        () async {
      install({pollCapdu: pollResponse});
      final t = CcidTransportBackend(CcidCard('fake')).nfcF();

      final pmm = await t.pmm;
      final pmmAgain = await t.pmm;

      expect(pmmAgain, pmm);
      expect(platform.sent, [pollCapdu]); // only sent once
    });
  });

  group('IsoDep transport', () {
    test('transceive passes the APDU straight through, SW included', () async {
      install({
        'FF00000004D44A0100': 'D54B01010004200404AABBCC9000',
        '00A4040000': '6A82',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).isoDep();
      platform.sent.clear();

      final r = await t.transceive(Uint8List.fromList([0, 0xA4, 4, 0, 0]));

      expect(platform.sent, ['00A4040000']);
      // SW is NOT stripped -- DESFire native mode has no SW at all.
      expect(r, Uint8List.fromList([0x6A, 0x82]));
    });

    test('historicalBytes is the card ATR', () async {
      install({'FF00000004D44A0100': 'D54B01010004200404AABBCC9000'});
      final atr = Uint8List.fromList([0x3B, 0x8F, 0x80]);
      final t = await CcidTransportBackend(CcidCard('fake', atr: atr)).isoDep();

      expect(t.historicalBytes, atr);
    });

    test(
        'isoDep() does not throw when the PN532 poll escape is rejected by '
        'a generic (non-ACS) CCID reader -- it degrades to an empty UID '
        'instead of taking down the whole driver (regression test: '
        'pollTypeA -> transceiveChecked throws on a non-9000 SW, and that '
        'used to propagate straight out of isoDep())', () async {
      install({
        // Instruction not supported -- what a reader lacking the PN532
        // escape dialect would return.
        'FF00000004D44A0100': '6D00',
        '00A4040000': '9000',
      });

      final t = await CcidTransportBackend(CcidCard('fake')).isoDep();

      expect(await t.uid, isEmpty);

      platform.sent.clear();
      final r = await t.transceive(Uint8List.fromList([0, 0xA4, 4, 0, 0]));
      expect(platform.sent, ['00A4040000']);
      expect(r, Uint8List.fromList([0x90, 0x00]));
    });
  });

  group('NfcB transport', () {
    test('nfcB() returns null when no Type B target answers', () async {
      install({'FF00000004D44A0103': 'D54B009000'}); // NbTg = 0
      final t = await CcidTransportBackend(CcidCard('fake')).nfcB();

      expect(t, isNull);
    });

    test('pupi is bytes 1-4 of ATQB', () async {
      // ATQB: 50 | PUPI(11223344) | AppData(4) | ProtocolInfo(3)
      // ATQB = 50 | PUPI(11223344) | AppData(AABBCCDD) | ProtocolInfo(010203)
      install({
        'FF00000004D44A0103':
            'D54B01015011223344AABBCCDD010203009000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).nfcB();

      expect(t!.pupi, Uint8List.fromList([0x11, 0x22, 0x33, 0x44]));
      expect(t.atqb.length, 12);
    });
  });
}
