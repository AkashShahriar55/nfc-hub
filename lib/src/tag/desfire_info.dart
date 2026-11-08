/// The parsed result of a MIFARE DESFire `GetVersion` (native command
/// `0x60`) exchange -- a 3-frame, 28-byte response identifying the exact
/// chip generation (EV1/EV2/EV3/...), distinct from and unrelated to the
/// Ultralight/NTAG `GET_VERSION` format (`ChipVersion` in
/// `tag_info.dart`).
class DesfireVersion {
  /// The hardware vendor ID. NXP is `0x04`.
  final int hardwareVendorId;

  /// The hardware type.
  final int hardwareType;

  /// The hardware subtype.
  final int hardwareSubtype;

  /// The hardware major version.
  final int hardwareMajor;

  /// The hardware minor version.
  final int hardwareMinor;

  /// The encoded hardware storage size.
  final int hardwareStorageSize;

  /// The hardware protocol type.
  final int hardwareProtocol;

  /// The software vendor ID.
  final int softwareVendorId;

  /// The software type.
  final int softwareType;

  /// The software subtype.
  final int softwareSubtype;

  /// The software major version.
  final int softwareMajor;

  /// The software minor version.
  final int softwareMinor;

  /// The encoded software storage size.
  final int softwareStorageSize;

  /// The software protocol type.
  final int softwareProtocol;

  /// The card's UID bytes.
  final List<int> uid;

  /// The production batch number bytes.
  final List<int> batch;

  /// The calendar week of production, as stored on the card.
  final int productionWeek;

  /// The year of production, as stored on the card.
  final int productionYear;

  /// Creates a version record from its decoded fields.
  const DesfireVersion({
    required this.hardwareVendorId,
    required this.hardwareType,
    required this.hardwareSubtype,
    required this.hardwareMajor,
    required this.hardwareMinor,
    required this.hardwareStorageSize,
    required this.hardwareProtocol,
    required this.softwareVendorId,
    required this.softwareType,
    required this.softwareSubtype,
    required this.softwareMajor,
    required this.softwareMinor,
    required this.softwareStorageSize,
    required this.softwareProtocol,
    required this.uid,
    required this.batch,
    required this.productionWeek,
    required this.productionYear,
  });
}

/// Resolves a generation label from [version]'s hardware type/major/minor
/// bytes, per the Proxmark3 project's field-validated `getCardType()`
/// table. Reports an explicit "unrecognized" message (with the raw bytes)
/// rather than guessing when the combination isn't in the table.
String desfireGenerationLabel(DesfireVersion version) {
  final type = version.hardwareType;
  final major = version.hardwareMajor;
  final minor = version.hardwareMinor;
  if (type == 0x01 && major == 0x00 && minor == 0x02) {
    return 'DESFire (original, MF3ICD40)';
  }
  if (type == 0x01 && major == 0x01 && minor == 0x00) return 'DESFire EV1';
  if (type == 0x01 && major == 0x12 && minor == 0x00) return 'DESFire EV2';
  if (type == 0x01 && major == 0x22 && minor == 0x00) {
    return 'DESFire EV2 XL';
  }
  if (type == 0x01 && major == 0x33 && minor == 0x00) return 'DESFire EV3';
  if (type == 0x81 && major == 0x43 && minor == 0x01) {
    return 'DESFire EV3 (microcontroller)';
  }
  if (type == 0x01 && major == 0xA0 && minor == 0x00) return 'DUOX';
  if (type == 0x08 && major == 0x30 && minor == 0x00) {
    return 'DESFire Light';
  }
  if (type == 0x81 && major == 0x42 && minor == 0x00) {
    return 'DESFire EV2 (combo DESFire/EMV)';
  }
  return 'Unrecognized DESFire generation (type=0x'
      '${type.toRadixString(16).padLeft(2, '0')}, major=0x'
      '${major.toRadixString(16).padLeft(2, '0')}, minor=0x'
      '${minor.toRadixString(16).padLeft(2, '0')})';
}
