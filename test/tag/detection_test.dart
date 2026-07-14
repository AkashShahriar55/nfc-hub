import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/transport.dart' show TagLostException;
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends NfcHubPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
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
    NfcHubPlatform.instance = null;
  });

  group('identifyTag() via ATR', () {
    test('recognizes a Type 2 Tag ATR', () async {
      // Real NTAG213/Ultralight-shaped historical bytes: shared RID
      // A0 00 00 03 06 followed by standard byte 0x03 (ISO14443A storage
      // family) and card-name byte 0x03 (Type 2/Ultralight). Under the old
      // RID-presence-only check this ATR would have wrongly resolved to
      // MifareClassicTag, since the shared RID alone used to trigger it.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes a MIFARE Classic 1K ATR by its RID marker', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = CcidCard('fake-reader', atr: atr);
      // The ATR alone identifies the family, but building a MifareClassicTag
      // now also requires a real PN532 poll (MifareClassicTransport exposes
      // uid/atqa/sak as sync getters) -- script its response: ATQA 0004,
      // SAK 08 (1K), UID 01020304.
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B010100040804010203049000',
      });

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test('recognizes a MIFARE Classic 4K ATR by its RID marker', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x02,
      ]);
      final card = CcidCard('fake-reader', atr: atr);
      // Same as above, but SAK 18 (4K).
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B010100041804010203049000',
      });

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test('recognizes a FeliCa ATR', () async {
      // Real FeliCa 212K ATR from ACS's ACR122U NFC Reader API (section
      // 7.3): shared RID A0 00 00 03 06, standard byte 0x03 (same as
      // MIFARE/Type2 — NOT 0x11), card name F0 11. Under the old
      // standard-byte-is-0x11 check this ATR would never have matched via
      // the RID path at all.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0xF0, 0x11,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
    });

    test(
        'degrades to probing (instead of hard-failing with TagLostException) '
        'when the ATR says MIFARE Classic but the PN532 Type A poll finds no '
        'target (regression test: MifareClassicTransport construction now '
        'does I/O -- a PN532 poll -- and can throw, whereas the ATR fast '
        'path used to be I/O-free and could not fail)', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = CcidCard('fake-reader', atr: atr);
      // NbTg=00 -- the PN532 reports no Type A target answered the poll --
      // for every poll attempt (both the ATR-path transport build and the
      // later MIFARE probe during fallback). Every other probe capdu is
      // left unconfigured, so _tryTransceive's catch-all treats them as "no
      // response", and the Type B poll's own try/catch treats the PN532's
      // "no fake response configured" error as a failed probe -- nothing
      // matches, so identifyTag() should surface a diagnosable
      // UnrecognizedTagException rather than the opaque TagLostException
      // that the failed poll actually threw.
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B009000',
      });

      try {
        await identifyTag(card);
        fail('expected identifyTag() to throw UnrecognizedTagException');
      } on TagLostException catch (e) {
        fail('identifyTag() hard-aborted with $e instead of degrading to '
            'capability probing');
      } on UnrecognizedTagException catch (e) {
        // The probe log proves detection actually ran every family's probe
        // (including a second, logged MIFARE attempt) rather than bailing
        // out early.
        expect(e.message, contains('MIFARE default-key auth'));
        expect(e.message, contains('TagLostException'));
      }
    });

    test('treats an unmarked ATR as a generic ISO-DEP card', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8A, 0x80, 0x01, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);
      // Building an IsoDepTransport now also does a real PN532 poll (for
      // its UID), same as the MIFARE Classic ATR case above -- script a
      // "no target found" (NbTg=00) response, since this test only cares
      // about the resolved driver type, not the UID.
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B009000',
      });

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });
  });

  group('identifyTag() probing fallback (no ATR)', () {
    test('recognizes a Type 2 Tag by its Capability Container', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': 'E11006009000',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes an ISO-DEP card via a SELECT response', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': '6A82',
        '00A4040000': '6A82',
        // Building the matched IsoDepTransport does a real PN532 poll (for
        // its UID); script a "no target found" response since this test
        // only cares about the resolved driver type.
        'FF00000004D44A0100': 'D54B009000',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });

    test(
        'recognizes an ISO-DEP card via a SELECT response even when the '
        'reader rejects the PN532 poll outright (regression test: a generic '
        'CCID reader without the PN532 escape dialect returns an error SW '
        'for the poll, not a graceful "no target found" -- that used to '
        'make isoDep() throw and identifyTag() hard-abort instead of '
        'degrading to an empty UID)', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': '6A82',
        '00A4040000': '6A82',
        // Instruction not supported -- what a reader lacking the PN532
        // escape dialect would return, instead of a "no target found" SW.
        'FF00000004D44A0100': '6D00',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });

    test('throws UnrecognizedTagException when nothing responds', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = CcidCard('fake-reader');

      expect(
        () => identifyTag(card),
        throwsA(isA<UnrecognizedTagException>()),
      );
    });

    test(
        'recognizes a FeliCa card by its IDm even though every other '
        'positive probe (Type 2 CC read, ISO-DEP SELECT, MIFARE auth) '
        'fails (regression test matching real ACR122U + FeliCa hardware: '
        'Get UID succeeds and returns the IDm, but nothing else does)',
        () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': 'AABBCCDDEE0011229000',
        'FFB0000304': '6A82',
        // '00A4040000' (SELECT) deliberately unmapped: the fake platform
        // throws for it, which _tryTransceive treats as "no response" —
        // an *error* status word (any 4+ hex chars) would otherwise
        // satisfy the SELECT probe's loose "got a response" heuristic and
        // misclassify this as IsoDepTag.
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
      expect(await (driver as FelicaTag).idm,
          equals([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x11, 0x22]));
    });

    test(
        "UnrecognizedTagException's message includes the ATR status and "
        'every probe outcome, so it is diagnosable from an on-screen error '
        'alone', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = CcidCard('fake-reader');

      try {
        await identifyTag(card);
        fail('expected identifyTag() to throw');
      } on UnrecognizedTagException catch (e) {
        expect(e.message, contains('atr=none'));
        expect(e.message, contains('Get UID'));
      }
    });

    test('recognizes a Type B card via the PN532 poll when nothing else '
        'matches', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': null,
        'FF00000004D44A0103':
            'D54B' '01' '01' '${'11' * 12}' '00' '9000',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<TypeBTag>());
    });
  });
}
