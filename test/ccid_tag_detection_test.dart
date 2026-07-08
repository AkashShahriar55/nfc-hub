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
      final atr = Uint8List.fromList(
          [0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C, 0x03, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes a MIFARE Classic ATR by its RID marker', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test('recognizes a FeliCa ATR', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C, 0x11, 0x00, 0x00]);
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
  });
}
