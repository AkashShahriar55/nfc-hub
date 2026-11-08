import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/pn532.dart';
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

  group('pollTypeA', () {
    test('parses a found target (ACS worked example)', () async {
      // Full response: D5 4B (InListPassiveTarget) 01 (NbTg) 01 (Tg)
      // 00 44 (ATQA) 08 (SAK) 07 (UID length) 04 01 02 03 04 05 06 (UID).
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B01010044080704010203040506' '9000',
      });
      final card = ReaderCard('fake-reader');

      final target = await pollTypeA(card);

      expect(target, isNotNull);
      expect(target!.atqa, equals([0x00, 0x44]));
      expect(target.sak, equals(0x08));
      expect(target.uid, equals([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]));
    });

    test('returns null when no target is found', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B00' '9000',
      });
      final card = ReaderCard('fake-reader');

      final target = await pollTypeA(card);

      expect(target, isNull);
    });
  });

  group('pollTypeB', () {
    test('parses a found target', () async {
      final atqb = List.filled(12, 0x11);
      final attrib = [0x22, 0x33];
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0103': [
          'D54B', // InListPassiveTarget response header
          '01', // NbTg
          '01', // Tg
          atqb.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '02', // ATTRIB_RES length
          attrib.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '9000',
        ].join().toUpperCase(),
      });
      final card = ReaderCard('fake-reader');

      final target = await pollTypeB(card);

      expect(target, isNotNull);
      expect(target!.atqb, equals(atqb));
      expect(target.attribResponse, equals(attrib));
    });

    test('returns null when no target is found', () async {
      NfcHubPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0103': 'D54B00' '9000',
      });
      final card = ReaderCard('fake-reader');

      final target = await pollTypeB(card);

      expect(target, isNull);
    });
  });
}
