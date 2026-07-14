import 'package:nfc_hub/src/tag/mifare_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mifareFamilyFromSak', () {
    test('identifies MIFARE Classic 1K (0x08)', () {
      expect(mifareFamilyFromSak(0x08), equals(MifareFamily.classic1k));
    });

    test('identifies MIFARE Classic 4K (0x18)', () {
      expect(mifareFamilyFromSak(0x18), equals(MifareFamily.classic4k));
    });

    test('identifies MIFARE Mini (0x09)', () {
      expect(mifareFamilyFromSak(0x09), equals(MifareFamily.mini));
    });

    test('identifies Ultralight/NTAG family (0x00)', () {
      expect(mifareFamilyFromSak(0x00),
          equals(MifareFamily.ultralightOrNtag));
    });

    test('identifies DESFire/Plus-SL3 via the 0x20 ISO14443-4 bit, even '
        'combined with other bits', () {
      expect(mifareFamilyFromSak(0x20),
          equals(MifareFamily.desfireOrPlusSl3));
      expect(mifareFamilyFromSak(0x24),
          equals(MifareFamily.desfireOrPlusSl3));
    });

    test('returns unknown for an unrecognized SAK', () {
      expect(mifareFamilyFromSak(0x04), equals(MifareFamily.unknown));
    });
  });

  group('mifareFamilyLabel', () {
    test('labels every family value', () {
      expect(mifareFamilyLabel(MifareFamily.classic1k),
          equals('MIFARE Classic 1K'));
      expect(mifareFamilyLabel(MifareFamily.classic4k),
          equals('MIFARE Classic 4K'));
      expect(mifareFamilyLabel(MifareFamily.mini), equals('MIFARE Mini'));
      expect(mifareFamilyLabel(MifareFamily.ultralightOrNtag),
          equals('MIFARE Ultralight / NTAG family'));
      expect(mifareFamilyLabel(MifareFamily.desfireOrPlusSl3),
          equals('MIFARE DESFire / MIFARE Plus (SL3)'));
      expect(mifareFamilyLabel(MifareFamily.unknown),
          equals('Unknown MIFARE-family card (SAK not recognized)'));
    });
  });
}
