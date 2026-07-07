import 'dart:typed_data';

import 'package:ccid/ccid_tag_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CapabilityContainer.parse', () {
    test('parses an NDEF-formatted CC', () {
      final bytes = Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]);

      final cc = CapabilityContainer.parse(bytes);

      expect(cc.magicByte, equals(0xE1));
      expect(cc.isNdefFormatted, isTrue);
      expect(cc.majorVersion, equals(1));
      expect(cc.minorVersion, equals(0));
      expect(cc.size, equals(0x06));
      expect(cc.dataAreaSize, equals(48));
      expect(cc.readAccess, equals(0x0));
      expect(cc.writeAccess, equals(0x0));
    });

    test('reports non-NDEF-formatted tags via magicByte', () {
      final bytes = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);

      final cc = CapabilityContainer.parse(bytes);

      expect(cc.isNdefFormatted, isFalse);
    });

    test('splits read/write access nibbles', () {
      final bytes = Uint8List.fromList([0xE1, 0x10, 0x06, 0xF0]);

      final cc = CapabilityContainer.parse(bytes);

      expect(cc.readAccess, equals(0xF));
      expect(cc.writeAccess, equals(0x0));
    });
  });

  group('ChipVersion.parse', () {
    test('parses an 8-byte GET_VERSION response', () {
      final bytes = Uint8List.fromList(
        [0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03],
      );

      final version = ChipVersion.parse(bytes);

      expect(version.headerByte, equals(0x00));
      expect(version.vendorId, equals(0x04));
      expect(version.productType, equals(0x04));
      expect(version.productSubtype, equals(0x02));
      expect(version.majorVersion, equals(0x01));
      expect(version.minorVersion, equals(0x00));
      expect(version.storageSize, equals(0x0F));
      expect(version.protocolType, equals(0x03));
    });
  });
}
