import 'dart:typed_data';

import 'package:ccid/ccid_felica_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('felicaModelName', () {
    test('identifies RC-SA01/2 (the confirmed Dhaka MRT chip)', () {
      final pmm = Uint8List.fromList(
          [0x03, 0x35, 0x42, 0x82, 0x82, 0x46, 0x8C, 0xFF]);

      expect(felicaModelName(pmm), equals('RC-SA01/2'));
    });

    test('identifies FeliCa Lite (RC-S965), which has no ROM constraint',
        () {
      final pmm = Uint8List.fromList(
          [0x00, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

      expect(felicaModelName(pmm), equals('FeliCa Lite (RC-S965)'));
    });

    test('returns null for an unrecognized IC code', () {
      final pmm = Uint8List.fromList(
          [0x00, 0xAB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

      expect(felicaModelName(pmm), isNull);
    });
  });

  group('felicaSystemCodeLabel', () {
    test('labels the Dhaka MRT system code', () {
      expect(felicaSystemCodeLabel(0x90E3), equals('MRT_PASS (Dhaka MRT/RapidPass)'));
    });

    test('labels the NFC Forum Type 3 Tag system code', () {
      expect(felicaSystemCodeLabel(0x12FC),
          equals('NFC Forum Type 3 Tag (NDEF)'));
    });

    test('returns null for an unrecognized system code', () {
      expect(felicaSystemCodeLabel(0x1234), isNull);
    });
  });
}
