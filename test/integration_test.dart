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
}
