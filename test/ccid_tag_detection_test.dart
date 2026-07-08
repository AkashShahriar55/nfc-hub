import 'dart:typed_data';

import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
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
    CcidPlatform.instance = null;
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

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test('recognizes a MIFARE Classic 4K ATR by its RID marker', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x02,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test('recognizes a FeliCa ATR', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x11, 0x00, 0x3B,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
    });

    test('treats an unmarked ATR as a generic ISO-DEP card', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8A, 0x80, 0x01, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });
  });

  group('identifyTag() probing fallback (no ATR)', () {
    test('recognizes a Type 2 Tag by its Capability Container', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': 'E11006009000',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes an ISO-DEP card via a SELECT response', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': '6A82',
        '00A4040000': '6A82',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });

    test('throws UnrecognizedTagException when nothing responds', () async {
      CcidPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = CcidCard('fake-reader');

      expect(
        () => identifyTag(card),
        throwsA(isA<UnrecognizedTagException>()),
      );
    });

    test(
        'recognizes a FeliCa card via polling even when Get UID fails '
        '(regression test: Get UID must not gate the other probes, since '
        "it's an ISO14443-A command and FeliCa is a different RF "
        'technology)', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': null,
        'FF000000060600FFFF0000': '0A01AABBCCDDEE0011229000',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
    });

    test(
        "UnrecognizedTagException's message includes the ATR status and "
        'every probe outcome, so it is diagnosable from an on-screen error '
        'alone', () async {
      CcidPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = CcidCard('fake-reader');

      try {
        await identifyTag(card);
        fail('expected identifyTag() to throw');
      } on UnrecognizedTagException catch (e) {
        expect(e.message, contains('atr=none'));
        expect(e.message, contains('Get UID'));
      }
    });
  });
}
