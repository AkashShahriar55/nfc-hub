import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
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
  Future<ReaderCard> connect(String reader) async => ReaderCard(reader);

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
      final card = ReaderCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes a MIFARE Classic 1K ATR by its RID marker', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = ReaderCard('fake-reader', atr: atr);
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
      final card = ReaderCard('fake-reader', atr: atr);
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
      final card = ReaderCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
    });

    test(
        'still resolves to MifareClassicTag (identity degraded, not the '
        'whole driver) when the ATR says MIFARE Classic but the PN532 Type '
        'A poll finds no target (regression test: the ATR is a stronger '
        'signal than the PN532 identity poll -- CcidTransportBackend.'
        'mifareClassic() never throws, so there is no reason to fall '
        'through to capability probing, and probing would risk grabbing '
        'the card under the wrong family entirely, see the misidentified-'
        'as-ISO-DEP regression covered in integration_test.dart)', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = ReaderCard('fake-reader', atr: atr);
      // NbTg=00 -- the PN532 reports no Type A target answered the poll.
      // MIFARE's actual operations (Load Key / General Authenticate) are
      // standard PC/SC Part 3 pseudo-APDUs needing no PN532 dialect, so
      // they are scripted to succeed even though the identity poll found
      // nothing.
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B009000',
        'FF82000006FFFFFFFFFFFF': '9000',
        'FF860000050100006000': '9000',
      });

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
      final mifare = driver as MifareClassicTag;

      // Identity is unavailable -- the poll found no target -- but the
      // driver itself is fully functional.
      final info = await mifare.readTagInfo();
      expect(info.uid, isEmpty);

      await mifare.authenticateWithDefaultKeys(0);
    });

    test('treats an unmarked ATR as a generic ISO-DEP card', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8A, 0x80, 0x01, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final card = ReaderCard('fake-reader', atr: atr);
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
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test(
        'recognizes a MIFARE Classic card by its SAK (from the PN532 poll) '
        'WITHOUT needing default-key auth -- a custom-key card, or one whose '
        'PC/SC pseudo-ATR was degenerate, is still MIFARE Classic', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '04AABBCC9000', // Get UID
        'FFB0000304': '6A82', // not Type 2
        // '00A4040000' (SELECT) unmapped -> not ISO-DEP.
        // PN532 Type A poll returns SAK 0x08 (MIFARE Classic 1K).
        'FF00000004D44A0100': 'D54B01010004080404AABBCC9000',
        // NO 'FF82...'/'FF86...' auth capdus scripted: if identifyTag tried to
        // authenticate, the fake would throw -- so this proves detection does
        // NOT depend on default-key auth succeeding.
      });
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
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
      final card = ReaderCard('fake-reader');

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
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });

    test('throws UnrecognizedTagException when nothing responds', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = ReaderCard('fake-reader');

      expect(
        () => identifyTag(card),
        throwsA(isA<UnrecognizedTagException>()),
      );
    });

    test(
        'a MIFARE Classic card whose reader answers SELECT with a failure '
        'SW is identified as MIFARE (SAK), not misclassified as ISO-DEP '
        '(regression: SELECT used to be probed BEFORE the MIFARE poll and '
        'accepted ANY >= 4 hex-char response as ISO-DEP proof, so the '
        "ACR122U's reader-level failure SW 6300 -- returned for a card it "
        "couldn't talk to via ISO7816 -- wrongly won over the authoritative "
        'SAK poll)', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '0102030449', // Get UID -- content irrelevant here
        'FFB0000304': '6300', // CC read fails -- not Type 2
        '00A4040000': '6300', // reader-level failure SW -- NOT ISO-DEP proof
        // PN532 InListPassiveTarget: Type A target, ATQA 0004, SAK 08
        // (MIFARE Classic 1K).
        'FF00000004D44A0100': 'D54B010100040804AABBCCDD9000',
      });
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test(
        'SELECT answered with a card-level ISO7816 SW still means ISO-DEP, '
        'even after a MIFARE poll finds a genuine (non-Classic) target',
        () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000', // Get UID ok
        'FFB0000304': '6A82', // CC read fails -- not Type 2
        // PN532 poll finds a real target, but SAK 0x20 (ISO14443-4
        // compliant, e.g. DESFire) is not a MIFARE Classic family -- the
        // MIFARE block must fall through instead of matching.
        'FF00000004D44A0100': 'D54B010103442004AABBCCDD9000',
        // 6A82 = file not found -- only an ISO7816 command interpreter on
        // the card produces that, unlike the reader-level 6300/6F00 SWs.
        '00A4040000': '6A82',
      });
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });

    test(
        'recognizes a FeliCa card by a FeliCa Polling response even though '
        'every other positive probe (Type 2 CC read, ISO-DEP SELECT, MIFARE '
        'auth) fails', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        // The FeliCa-specific Polling command answers -> genuinely NFC-F.
        'FF00000009D440010600FFFF0000':
            'D541001201AABBCCDDEE0011220102030405060708' '9000',
        'FFCA000000': 'AABBCCDDEE0011229000', // Get UID (for the .idm read)
        'FFB0000304': '6A82', // not Type 2
        // '00A4040000' (SELECT) and the Type A poll are deliberately unmapped:
        // the fake throws for them, so ISO-DEP and MIFARE probes fail first.
      });
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
      expect(await (driver as FelicaTag).idm,
          equals([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x11, 0x22]));
    });

    test(
        'a card that answers Get UID but NOT a FeliCa Polling is NOT '
        'misidentified as FeliCa (regression: a MIFARE card whose '
        'default-key auth failed used to be caught by the Get-UID-based '
        'FeliCa probe)', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        // Answers Get UID (as any ISO14443-A card does)...
        'FFCA000000': '04AABBCC9000',
        'FFB0000304': '6A82', // not Type 2
        // ...but the FeliCa Polling, the Type A poll (MIFARE), the SELECT,
        // and the Type B poll are all unmapped -> the fake throws -> every
        // family probe fails. The card must NOT come back as FelicaTag.
      });
      final card = ReaderCard('fake-reader');

      await expectLater(
        identifyTag(card),
        throwsA(isA<UnrecognizedTagException>()),
      );
    });

    test(
        "UnrecognizedTagException's message includes the ATR status and "
        'every probe outcome, so it is diagnosable from an on-screen error '
        'alone', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = ReaderCard('fake-reader');

      try {
        await identifyTag(card);
        fail('expected identifyTag() to throw');
      } on UnrecognizedTagException catch (e) {
        expect(e.message, contains('atr=none'));
        expect(e.message, contains('Get UID'));
      }
    });

    test(
        'recognizes a Type B card via the PN532 poll when nothing else '
        'matches', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': null,
        'FF00000004D44A0103': 'D54B' '01' '01' '${'11' * 12}' '00' '9000',
      });
      final card = ReaderCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<TypeBTag>());
    });
  });
}
