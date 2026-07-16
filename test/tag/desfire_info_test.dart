import 'package:nfc_hub/src/tag/desfire_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desfireGenerationLabel identifies the original DESFire (MF3ICD40)',
      () {
    const version = DesfireVersion(
      hardwareVendorId: 0x04,
      hardwareType: 0x01,
      hardwareSubtype: 0x01,
      hardwareMajor: 0x00,
      hardwareMinor: 0x02,
      hardwareStorageSize: 0x18,
      hardwareProtocol: 0x05,
      softwareVendorId: 0x04,
      softwareType: 0x01,
      softwareSubtype: 0x01,
      softwareMajor: 0x00,
      softwareMinor: 0x06,
      softwareStorageSize: 0x18,
      softwareProtocol: 0x05,
      uid: [0x04, 0x52, 0x5A, 0x19, 0xB2, 0x1B, 0x80],
      batch: [0x8E, 0x36, 0x54, 0x4D, 0x40],
      productionWeek: 0x26,
      productionYear: 0x04,
    );

    expect(desfireGenerationLabel(version),
        equals('DESFire (original, MF3ICD40)'));
  });

  test('desfireGenerationLabel identifies DESFire EV1', () {
    const version = DesfireVersion(
      hardwareVendorId: 0x04,
      hardwareType: 0x01,
      hardwareSubtype: 0x01,
      hardwareMajor: 0x01,
      hardwareMinor: 0x00,
      hardwareStorageSize: 0x18,
      hardwareProtocol: 0x05,
      softwareVendorId: 0x04,
      softwareType: 0x01,
      softwareSubtype: 0x01,
      softwareMajor: 0x01,
      softwareMinor: 0x00,
      softwareStorageSize: 0x18,
      softwareProtocol: 0x05,
      uid: [0, 0, 0, 0, 0, 0, 0],
      batch: [0, 0, 0, 0, 0],
      productionWeek: 0,
      productionYear: 0,
    );

    expect(desfireGenerationLabel(version), equals('DESFire EV1'));
  });

  test('desfireGenerationLabel reports an unrecognized combination '
      'explicitly rather than guessing', () {
    const version = DesfireVersion(
      hardwareVendorId: 0x04,
      hardwareType: 0xFF,
      hardwareSubtype: 0x01,
      hardwareMajor: 0xFF,
      hardwareMinor: 0xFF,
      hardwareStorageSize: 0x18,
      hardwareProtocol: 0x05,
      softwareVendorId: 0x04,
      softwareType: 0xFF,
      softwareSubtype: 0x01,
      softwareMajor: 0xFF,
      softwareMinor: 0xFF,
      softwareStorageSize: 0x18,
      softwareProtocol: 0x05,
      uid: [0, 0, 0, 0, 0, 0, 0],
      batch: [0, 0, 0, 0, 0],
      productionWeek: 0,
      productionYear: 0,
    );

    expect(
        desfireGenerationLabel(version),
        equals('Unrecognized DESFire generation (type=0xff, major=0xff, '
            'minor=0xff)'));
  });
}
