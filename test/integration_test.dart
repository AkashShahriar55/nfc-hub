/// Full-stack tests: a scripted CCID reader at the wire level, through the
/// real CcidTransportBackend and the real drivers, to a decoded result.
///
/// The per-layer tests (test/transport/ccid_backend_test.dart for the wire
/// bytes, test/tag/*_test.dart for driver logic over fake transports) each
/// only prove their own half. These prove the halves agree.
///
/// As each driver is migrated onto its transport, add a group here for it.
library;

import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every C-APDU sent and replies from a scripted map, the same as a
/// real reader would over the platform channel.
class _FakeCcidPlatform extends NfcHubPlatform {
  final Map<String, String> responses;
  final List<String> requestedCapdus = [];

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
    final response = responses[capdu];
    if (response == null) {
      throw Exception('No fake response configured for capdu: $capdu');
    }
    return response;
  }

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

/// Like [_FakeCcidPlatform], but returns each response in [responses] in
/// order rather than keying by capdu. Needed for ISO-DEP's DESFire
/// GetVersion exchange, which sends the very same continuation APDU
/// ('AF') twice in a row, each expecting a different response -- a keyed
/// map can't represent that.
class _SequencedFakeCcidPlatform extends NfcHubPlatform {
  final List<String> responses;
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
    NfcHubPlatform.instance = null;
  });

  group('Type 2', () {
    test(
        'identifyTag() detects a Type 2 tag by its Capability Container and '
        'the resulting driver reads back a decoded NDEF message', () async {
      // CC: magic 0xE1, version 0x10, size 0x06 (48-byte data area), access 0x00.
      // Detection's capability probe (see lib/src/tag/detection.dart's
      // _identifyByProbing) treats a 4-byte response starting with 0xE1 as a
      // Type 2 match; readNdef() re-reads the same page 3 afterwards.
      final ccData = [0xE1, 0x10, 0x06, 0x00];
      final ccResponse = '${hex.encode(ccData)}9000';

      // NDEF Text record 'hello', wrapped in a Message TLV + Terminator.
      final record = [
        0xD1, 0x01, 0x08, 0x54, // flags, typeLength, payloadLength, type 'T'
        0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
        0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
      ];
      final page4 = [0x03, record.length, ...record, 0xFE, 0x00, 0x00];
      final page4Response = '${hex.encode(page4)}9000';

      final fake = _FakeCcidPlatform({
        // No 'FFCA000000' entry: identifyTag's Get UID probe is allowed to
        // fail (it's ISO14443-A specific), so the fake throws for it and
        // detection's _tryTransceive() catches that and moves on.
        'FFB0000304': ccResponse,
        'FFB0000410': page4Response,
      });
      NfcHubPlatform.instance = fake;

      // No ATR: this card connected without one, so identifyTag() must fall
      // back to capability probing (lib/src/tag/detection.dart's
      // _identifyByProbing) to reach a Type2Tag -- exercising the same
      // detection path a real headless CCID connect would take.
      final card = CcidCard('fake-reader');
      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
      final records = await (driver as Type2Tag).readNdef();

      expect(records, hasLength(1));
      expect(records[0].asText, equals('hello'));

      // Guards the wire format end to end: a 5-byte READ BINARY
      // (FF B0 00 <page> <Le>) with the page number in P2. The historical
      // bug here sent a 6-byte APDU ('FFB00000<page>10') with P2 stuck at
      // 00, so every page read silently returned page 0 instead.
      expect(
        fake.requestedCapdus,
        contains('FFB0000410'),
        reason: 'expected a 5-byte READ BINARY APDU (FF B0 00 <page> <Le>) '
            'with the page number in P2, matching the same pattern the '
            'Capability Container read already uses',
      );
    });
  });

  group('MIFARE Classic', () {
    test(
        'identifyTag() detects a MIFARE Classic 1K tag by capability probing '
        'and the resulting driver authenticates and reads back a decoded '
        'sector', () async {
      // InListPassiveTarget reply: numTargets=01, Tg=01, ATQA=0004, SAK=08
      // (1K), UID=04AABBCC.
      const pollResponse = 'D54B01010004080404AABBCC9000';

      final block0 = List.filled(16, 0x11);
      final block1 = List.filled(16, 0x22);
      final block2 = List.filled(16, 0x33);
      final block3 = List.filled(16, 0x44);

      final fake = _FakeCcidPlatform({
        // No 'FFCA000000' or '00A4040000' entries: identifyTag's Get UID and
        // SELECT probes are allowed to fail (they're ISO14443-A/ISO-DEP
        // specific, not the PN532 poll MIFARE actually relies on), so the
        // fake throws for them and detection's _tryTransceive() catches
        // that and moves on -- same pattern as detection_test.dart's FeliCa
        // fallback regression test.
        'FFB0000304': '6A82', // Read CC fails -> not a Type 2 tag.
        'FF00000004D44A0100': pollResponse, // PN532 poll (Type A).
        'FF82000006FFFFFFFFFFFF': '9000', // Load Key (default key A).
        'FF860000050100006000': '9000', // General Authenticate, block 0.
        'FFB0000010': '${hex.encode(block0)}9000',
        'FFB0000110': '${hex.encode(block1)}9000',
        'FFB0000210': '${hex.encode(block2)}9000',
        'FFB0000310': '${hex.encode(block3)}9000',
      });
      NfcHubPlatform.instance = fake;

      // No ATR: falls back to capability probing, same as the Type 2 group
      // above -- exercising the same detection path a real headless CCID
      // connect would take. The probe order (Type 2 CC, ISO-DEP SELECT,
      // then MIFARE) means both prior probes must fail first.
      final card = CcidCard('fake-reader');
      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
      final tag = driver as MifareClassicTag;

      await tag.authenticateWithDefaultKeys(0);
      final blocks = await tag.readSector(0);

      expect(blocks, hasLength(4));
      expect(blocks[0], equals(block0));
      expect(blocks[1], equals(block1));
      expect(blocks[2], equals(block2));
      expect(blocks[3], equals(block3));

      // Guards the wire format end to end: the PN532 poll, then Load Key
      // (slot 00, the default key A as uppercase hex) and General
      // Authenticate (block 00, key type A = 0x60, slot 00) pseudo-APDUs
      // the backend must send for authenticateWithDefaultKeys(0), and the
      // READ BINARY reads for all 4 blocks of sector 0.
      expect(
        fake.requestedCapdus,
        containsAllInOrder([
          'FF00000004D44A0100',
          'FF82000006FFFFFFFFFFFF',
          'FF860000050100006000',
          'FFB0000010',
          'FFB0000110',
          'FFB0000210',
          'FFB0000310',
        ]),
      );
    });
  });

  group('FeliCa', () {
    test(
        'identifyTag() detects a FeliCa tag by ATR and the resulting driver '
        'reads back a decoded block via a Read Without Encryption wrapped '
        'in a PN532 InDataExchange command', () async {
      // Real FeliCa 212K ATR from ACS's ACR122U NFC Reader API (section
      // 7.3): shared RID A0 00 00 03 06, standard byte 0x03, card name
      // F0 11 -- same ATR as test/tag/detection_test.dart's FeliCa case.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0xF0, 0x11,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      const idmHex = 'AABBCCDDEE001122';
      // idm is read via the standard PC/SC Get UID pseudo-APDU, which
      // returns the FeliCa IDm on ACR-family readers.
      const uidCapdu = 'FFCA000000';
      const uidResponse = '${idmHex}9000';

      // Read Without Encryption (cmd=06) for service code 0x220F, block 0:
      // frame = 06 | idm(8) | numServices=01 | serviceCode LE (0F22) |
      // numBlocks=01 | blockListElement(80,00) -> 15 bytes, length-prefixed
      // to 16 bytes (leading byte 0x10), wrapped in D4 40 01 (PN532
      // InDataExchange, target #1) -> 19-byte payload -> Lc=13.
      const readCapdu =
          'FF00000013D440011006AABBCCDDEE001122010F22018000';
      // Response: D5 41 00 (InDataExchange success) + FeliCa response frame
      // (29 bytes): len=1D, respCode=07, idm(8), SF1=00, SF2=00,
      // numBlocks=01, block(16 bytes of 0xAA).
      const readResponse = 'D541001D07AABBCCDDEE001122000001'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          '9000';

      final fake = _FakeCcidPlatform({
        uidCapdu: uidResponse,
        readCapdu: readResponse,
      });
      NfcHubPlatform.instance = fake;

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
      final result =
          await (driver as FelicaTag).readWithoutEncryption(0x220F, [0]);

      expect(result.isSuccess, isTrue);
      expect(result.blocks, hasLength(1));
      expect(result.blocks[0], equals(List.filled(16, 0xAA)));

      // Guards the wire format end to end: the driver's frame construction
      // (command code, IDm, little-endian service code, block list) must
      // survive being wrapped by the backend in the PN532 InDataExchange
      // command (D4 40 01) exactly as a real ACR122U expects it.
      expect(fake.requestedCapdus, contains(readCapdu));
    });
  });

  group('ISO-DEP', () {
    test(
        'identifyTag() detects a generic ISO-DEP card via an unmarked ATR '
        'and the resulting driver decodes a real 3-frame native DESFire '
        'GetVersion exchange', () async {
      // A real ATS-derived ATR (not a PC/SC Part 3 synchronous-card
      // pseudo-ATR) with none of the Type 2/MIFARE/FeliCa RID markers --
      // same shape as test/tag/detection_test.dart's "unmarked ATR" case --
      // so identifyTag() falls all the way through _identifyFromAtr to the
      // generic ISO-DEP branch.
      final atr = Uint8List.fromList(
          [0x3B, 0x8A, 0x80, 0x01, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      // Building the resolved IsoDepTransport does a real PN532 poll for
      // the UID (InListPassiveTarget): numTargets=01, Tg=01, ATQA=0344,
      // SAK=20 (ISO14443-4 compliant), UID=04112233.
      final pollBytes = [
        0xD5, 0x4B, 0x01, 0x01, 0x03, 0x44, 0x20, 0x04, 0x04, 0x11, 0x22, 0x33,
      ];
      final pollResponse = '${hex.encode(pollBytes)}9000';

      // The three ACS-documented DESFire GetVersion frames (same fixture
      // bytes carried over byte for byte from test/tag/iso_dep_test.dart),
      // sent as three native '60'/'AF'/'AF' exchanges. Per ACS's ACR122U
      // documentation these carry NO PC/SC status word at all -- this is
      // the exact behavior this task must not silently break.
      final fake = _SequencedFakeCcidPlatform([
        pollResponse,
        'AF04010100021805',
        'AF04010100061805',
        '0004525A19B21B808E36544D402604',
      ]);
      NfcHubPlatform.instance = fake;

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
      final version = await (driver as IsoDepTag).readDesfireVersion();

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

      // Guards the wire format end to end: the PN532 poll, then exactly
      // three native DESFire frames ('60' then 'AF' twice) with no ISO
      // wrapping and no status word expected on the way in either --
      // matching the C-APDUs ACS's worked example documents.
      expect(
        fake.requestedCapdus,
        equals(['FF00000004D44A0100', '60', 'AF', 'AF']),
      );
    });
  });

  group('Type B', () {
    test(
        'identifyTag() detects an ISO14443-B tag via the last-resort PN532 '
        'poll after every earlier probe fails, and the resulting driver '
        'reads back a decoded ATQB/PUPI and passes an APDU through', () async {
      // ATQB, per ISO14443-3: '50' | PUPI(4) | AppData(4) | ProtocolInfo(3).
      final atqb = [
        0x50, 0xAA, 0xBB, 0xCC, 0xDD, //
        0x01, 0x02, 0x03, 0x04, //
        0x05, 0x06, 0x07,
      ];
      // InListPassiveTarget reply: numTargets=01, Tg=01, ATQB (12 bytes),
      // ATTRIB_RES length=00 (none) -- same shape as
      // test/tag/detection_test.dart's Type B case and
      // test/transport/pn532_test.dart's pollTypeB fixture.
      final pollResponse =
          '${'D54B0101${hex.encode(atqb)}00'.toUpperCase()}9000';

      final fake = _FakeCcidPlatform({
        // Every earlier probe (Get UID, Read CC, SELECT, MIFARE's PN532
        // Type A poll, FeliCa's Get UID) is left unmapped -- the fake
        // throws for each and detection's own try/catch (or
        // _tryTransceive) treats that as "no match", same pattern as
        // detection_test.dart's Type B regression test -- so identifyTag()
        // falls all the way through to the last-resort Type B poll.
        'FF00000004D44A0103': pollResponse,
        // A raw APDU passed through once the driver is constructed.
        '00B0000000': 'AABB9000',
      });
      NfcHubPlatform.instance = fake;

      final card = CcidCard('fake-reader');
      final driver = await identifyTag(card);

      expect(driver, isA<TypeBTag>());
      final tag = driver as TypeBTag;

      final info = await tag.readTagInfo();
      expect(info.uid, equals([0xAA, 0xBB, 0xCC, 0xDD]));
      expect(info.atqb, equals(atqb));

      final response = await tag.transceive('00B0000000');
      expect(response, equals('AABB9000'));

      // Guards the wire format end to end: every earlier probe (Get UID,
      // Read CC, SELECT, MIFARE's Type A poll, FeliCa's Get UID) runs and
      // fails first -- proving Type B really is the last-resort fallback
      // -- and only then does the last-resort poll use brTy=0x03 (Type B),
      // not 0x00 (Type A).
      expect(
        fake.requestedCapdus,
        containsAllInOrder([
          'FFCA000000', // Get UID probe
          'FFB0000304', // Read CC probe
          '00A4040000', // SELECT probe
          'FF00000004D44A0100', // MIFARE's Type A poll
          'FFCA000000', // FeliCa's Get UID (idm)
          'FF00000004D44A0103', // Type B poll (brTy=0x03)
          '00B0000000', // post-construction APDU passthrough
        ]),
      );
    });
  });

  group('ATR restoration (Task 8)', () {
    // Tasks 3-7 moved Type2Tag, MifareClassicTag, FelicaTag, and TypeBTag
    // onto typed transports, and each one lost its ATR in the process
    // (hardcoded to null). Task 8 has identifyTag() -- which holds the
    // CcidCard and therefore the real ATR -- inject it back into the driver
    // at construction time. These tests prove readTagInfo().atr actually
    // carries the card's ATR through identifyTag(), for all five driver
    // families (four restored here, plus IsoDepTag's pre-existing path via
    // transport.historicalBytes for completeness).

    test('Type2Tag: readTagInfo().atr matches the ATR identifyTag() '
        'resolved it from', () async {
      // Same Type 2-shaped ATR as detection_test.dart's ATR-fast-path case.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '040102039000', // readUid()
        'FFB0000304': 'E11006009000', // readCapabilityContainer()
      });

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
      final info = await (driver as Type2Tag).readTagInfo();
      expect(info.atr, equals(atr));
    });

    test('MifareClassicTag: readTagInfo().atr matches the ATR identifyTag() '
        'resolved it from', () async {
      // Same MIFARE Classic 1K-shaped ATR as detection_test.dart's
      // ATR-fast-path case.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      // PN532 poll (Type A): ATQA 0004, SAK 08 (1K), UID 01020304 -- the
      // transport build itself does this I/O when constructed from the ATR
      // fast path.
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B010100040804010203049000',
      });

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
      final info = await (driver as MifareClassicTag).readTagInfo();
      expect(info.atr, equals(atr));
    });

    test(
        'FelicaTag: readTagInfo().atr matches the ATR identifyTag() '
        'resolved it from', () async {
      // Same FeliCa-shaped ATR as this file's own FeliCa group above.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0xF0, 0x11,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      // readTagInfo() awaits both idm (Get UID pseudo-APDU) and pmm (a
      // FeliCa polling command wrapped in the PN532 InDataExchange escape)
      // unconditionally, so both must be scripted.
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': 'AABBCCDDEE0011229000', // idm
        // FeliCa polling frame (cmd 0x00, wildcard system code, no request
        // code, time slot 0) wrapped in D4 40 01 -> response:
        // D5 41 00 (InDataExchange success) + len | respCode=01 | idm(8) |
        // pmm(8).
        'FF00000009D440010600FFFF0000':
            'D541001101AABBCCDDEE00112201020304050607089000',
      });

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
      final info = await (driver as FelicaTag).readTagInfo();
      expect(info.atr, equals(atr));
    });

    test(
        'TypeBTag: readTagInfo().atr matches the (non-matching) ATR '
        "identifyTag() carried through to the probing fallback, proving "
        'the ATR is threaded through even when it degrades past the ATR '
        'fast path', () async {
      // Same MIFARE Classic 1K-shaped ATR as the MifareClassicTag case
      // above, but this time the PN532 poll finds no target (NbTg=00) for
      // every Type A poll attempt, so _identifyFromAtr's MIFARE branch
      // degrades to probing (same regression covered in
      // detection_test.dart) with this non-null ATR carried along. Every
      // earlier probe is left unscripted (Get UID, Read CC, SELECT, and the
      // FeliCa idm all throw and get caught), so detection falls all the
      // way to the last-resort Type B poll.
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final atqb = [
        0x50, 0xAA, 0xBB, 0xCC, 0xDD, //
        0x01, 0x02, 0x03, 0x04, //
        0x05, 0x06, 0x07,
      ];
      final pollResponse =
          '${'D54B0101${hex.encode(atqb)}00'.toUpperCase()}9000';

      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B009000', // Type A poll: no target found.
        'FF00000004D44A0103': pollResponse, // Type B poll: target found.
      });

      final driver = await identifyTag(card);

      expect(driver, isA<TypeBTag>());
      final info = await (driver as TypeBTag).readTagInfo();
      expect(info.atr, equals(atr));
    });

    test('IsoDepTag: readTagInfo().atr matches the card ATR via '
        'transport.historicalBytes (pre-existing path, unaffected by Task '
        '8 -- covered here so all five driver families are asserted '
        'together)', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8A, 0x80, 0x01, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B009000', // PN532 poll: no target found.
      });

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
      final info = await (driver as IsoDepTag).readTagInfo();
      expect(info.atr, equals(atr));
    });
  });
}
