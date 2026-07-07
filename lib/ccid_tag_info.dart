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
/// Forum Type 2 Tag operation set — see `CcidCard.readChipVersion`.
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
  String toString() =>
      'ChipVersion(vendorId: 0x${vendorId.toRadixString(16)}, '
      'productType: 0x${productType.toRadixString(16)}, '
      'productSubtype: 0x${productSubtype.toRadixString(16)}, '
      'version: $majorVersion.$minorVersion, '
      'storageSize: 0x${storageSize.toRadixString(16)}, '
      'protocolType: 0x${protocolType.toRadixString(16)})';
}
