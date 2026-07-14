/// Full-stack tests: a scripted CCID reader at the wire level, through the
/// real CcidTransportBackend and the real drivers, to a decoded result.
///
/// The per-layer tests (test/transport/ccid_backend_test.dart for the wire
/// bytes, test/tag/*_test.dart for driver logic over fake transports) each
/// only prove their own half. These prove the halves agree.
///
/// As each driver is migrated onto its transport, add a group here for it.
library;

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
}
