import 'dart:typed_data';

/// The parsed Capability Container (CC) of an NFC Forum Type 2 Tag.
///
/// The CC is 4 bytes, normally found at page 3 of the tag's memory.
class CapabilityContainer {
  /// The NDEF magic number byte. `0xE1` indicates the tag is NDEF-formatted.
  final int magicByte;

  /// The CC version byte (high nibble = major, low nibble = minor).
  final int version;

  /// The raw size byte. Data area size in bytes is [dataAreaSize].
  final int size;

  /// The raw read/write access byte (high nibble = read, low nibble = write).
  final int accessByte;

  CapabilityContainer({
    required this.magicByte,
    required this.version,
    required this.size,
    required this.accessByte,
  });

  /// Whether [magicByte] indicates this tag is NDEF-formatted.
  bool get isNdefFormatted => magicByte == 0xE1;

  /// The NDEF data area size in bytes, derived from [size].
  int get dataAreaSize => size * 8;

  /// The major version number, from the high nibble of [version].
  int get majorVersion => (version >> 4) & 0x0F;

  /// The minor version number, from the low nibble of [version].
  int get minorVersion => version & 0x0F;

  /// The read access condition, from the high nibble of [accessByte].
  int get readAccess => (accessByte >> 4) & 0x0F;

  /// The write access condition, from the low nibble of [accessByte].
  int get writeAccess => accessByte & 0x0F;

  /// Parses a 4-byte Capability Container.
  static CapabilityContainer parse(Uint8List bytes) {
    return CapabilityContainer(
      magicByte: bytes[0],
      version: bytes[1],
      size: bytes[2],
      accessByte: bytes[3],
    );
  }

  @override
  String toString() =>
      'CapabilityContainer(magicByte: 0x${magicByte.toRadixString(16)}, '
      'version: $majorVersion.$minorVersion, dataAreaSize: $dataAreaSize, '
      'readAccess: 0x${readAccess.toRadixString(16)}, '
      'writeAccess: 0x${writeAccess.toRadixString(16)})';
}

/// The parsed response to an NXP `GET_VERSION` (0x60) command, identifying
/// the chip model of an NTAG21x / Mifare Ultralight family tag.
///
/// This is a manufacturer-specific command, not part of the standard NFC
/// Forum Type 2 Tag operation set — see `ReaderCard.readChipVersion`.
class ChipVersion {
  final int headerByte;
  final int vendorId;
  final int productType;
  final int productSubtype;
  final int majorVersion;
  final int minorVersion;
  final int storageSize;
  final int protocolType;

  ChipVersion({
    required this.headerByte,
    required this.vendorId,
    required this.productType,
    required this.productSubtype,
    required this.majorVersion,
    required this.minorVersion,
    required this.storageSize,
    required this.protocolType,
  });

  /// Parses an 8-byte GET_VERSION response.
  static ChipVersion parse(Uint8List bytes) {
    return ChipVersion(
      headerByte: bytes[0],
      vendorId: bytes[1],
      productType: bytes[2],
      productSubtype: bytes[3],
      majorVersion: bytes[4],
      minorVersion: bytes[5],
      storageSize: bytes[6],
      protocolType: bytes[7],
    );
  }

  @override
  String toString() => 'ChipVersion(vendorId: 0x${vendorId.toRadixString(16)}, '
      'productType: 0x${productType.toRadixString(16)}, '
      'productSubtype: 0x${productSubtype.toRadixString(16)}, '
      'version: $majorVersion.$minorVersion, '
      'storageSize: 0x${storageSize.toRadixString(16)}, '
      'protocolType: 0x${protocolType.toRadixString(16)})';
}

class _UltralightModelEntry {
  final int vendorId;
  final int productType;
  final int productSubtype;
  final int majorVersion;
  final int minorVersion;
  final int storageSize;
  final int protocolType;
  final String name;

  const _UltralightModelEntry(
    this.vendorId,
    this.productType,
    this.productSubtype,
    this.majorVersion,
    this.minorVersion,
    this.storageSize,
    this.protocolType,
    this.name,
  );
}

/// Known MIFARE Ultralight/NTAG `GET_VERSION` tuples, sourced from NXP's
/// NTAG213/215/216 and MF0ULX1 datasheets plus the Proxmark3 project's
/// field-validated `ul_family[]` table.
const _ultralightModels = <_UltralightModelEntry>[
  _UltralightModelEntry(
      0x04, 0x03, 0x01, 0x00, 0x00, 0x0B, 0x03, 'MIFARE Ultralight'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x01, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight EV1 (48B, 17pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x02, 0x01, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight EV1 (48B, 50pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x01, 0x00, 0x0E, 0x03,
      'MIFARE Ultralight EV1 (128B, 17pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x02, 0x01, 0x00, 0x0E, 0x03,
      'MIFARE Ultralight EV1 (128B, 50pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x02, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight Nano 40B (17pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x03, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight Nano (17pF)'),
  _UltralightModelEntry(0x04, 0x04, 0x01, 0x01, 0x00, 0x0B, 0x03, 'NTAG 210'),
  _UltralightModelEntry(0x04, 0x04, 0x02, 0x01, 0x00, 0x0B, 0x03, 'NTAG 210'),
  _UltralightModelEntry(0x04, 0x04, 0x01, 0x01, 0x00, 0x0E, 0x03, 'NTAG 212'),
  _UltralightModelEntry(0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03, 'NTAG 213'),
  _UltralightModelEntry(0x04, 0x04, 0x04, 0x01, 0x00, 0x0F, 0x03, 'NTAG 213F'),
  _UltralightModelEntry(0x04, 0x04, 0x02, 0x01, 0x01, 0x0F, 0x03, 'NTAG 213C'),
  _UltralightModelEntry(0x04, 0x04, 0x02, 0x03, 0x00, 0x0F, 0x03, 'NTAG 213TT'),
  _UltralightModelEntry(0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03, 'NTAG 215'),
  _UltralightModelEntry(0x04, 0x04, 0x04, 0x01, 0x00, 0x11, 0x03, 'NTAG 215F'),
  _UltralightModelEntry(0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03, 'NTAG 216'),
  _UltralightModelEntry(0x04, 0x04, 0x04, 0x01, 0x00, 0x13, 0x03, 'NTAG 216F'),
];

/// Resolves an exact NXP model name from [version], falling back to a
/// coarse family label (`productType`: `0x03` -> Ultralight family,
/// `0x04` -> NTAG family) if the exact tuple isn't in the table, matching
/// Proxmark3's own fallback strategy. Returns `null` for a non-NXP vendor
/// ID (`version.vendorId != 0x04`).
String? ultralightModelName(ChipVersion version) {
  for (final entry in _ultralightModels) {
    if (entry.vendorId == version.vendorId &&
        entry.productType == version.productType &&
        entry.productSubtype == version.productSubtype &&
        entry.majorVersion == version.majorVersion &&
        entry.minorVersion == version.minorVersion &&
        entry.storageSize == version.storageSize &&
        entry.protocolType == version.protocolType) {
      return entry.name;
    }
  }
  if (version.vendorId != 0x04) return null;
  if (version.productType == 0x03) {
    return 'MIFARE Ultralight family (unrecognized exact model)';
  }
  if (version.productType == 0x04) {
    return 'NTAG family (unrecognized exact model)';
  }
  return null;
}
