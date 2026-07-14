import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'mifare_info.dart';
import 'tag_driver.dart';
import '../apdu.dart';
import '../nfc_hub_base.dart';
import '../pn532.dart';

/// Which MIFARE Classic key slot (A or B) to authenticate with.
enum MifareKeyType { a, b }

/// Thrown by [MifareClassicTag] authentication methods when a key is
/// rejected by the card. This is an expected, catchable outcome (wrong key
/// or wrong sector), not a bug.
class MifareAuthException implements Exception {
  final String message;

  const MifareAuthException(this.message);

  @override
  String toString() => 'MifareAuthException: $message';
}

class MifareClassicInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;
  final int sak;
  final Uint8List atqa;

  const MifareClassicInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.sak,
    required this.atqa,
  });
}

/// Driver for a MIFARE Classic 1K/4K tag connected through a contactless
/// PC/SC reader.
///
/// Reads require authenticating the target sector first, via [authenticate]
/// or [authenticateWithDefaultKeys]. The reader performs the MIFARE stream
/// cipher itself; this driver only sends the PC/SC "Load Keys" and "General
/// Authenticate" pseudo-APDUs (PC/SC Part 3).
class MifareClassicTag extends TagDriver {
  final CcidCard card;

  MifareClassicTag(this.card);

  static const List<String> _defaultKeysHex = [
    'FFFFFFFFFFFF',
    'A0A1A2A3A4A5',
    'D3F7D3F7D3F7',
    '000000000000',
  ];

  static const int _keySlot = 0x00;

  /// Loads [key] (6 bytes) into the reader and authenticates [sector] with
  /// it as key [keyType].
  ///
  /// Throws [MifareAuthException] if the key is rejected.
  Future<void> authenticate(
    int sector,
    MifareKeyType keyType,
    Uint8List key,
  ) async {
    if (key.length != 6) {
      throw ArgumentError(
          'MIFARE Classic keys are 6 bytes, got ${key.length}');
    }
    await _loadKey(key);
    await _generalAuthenticate(_blockForSector(sector), keyType);
  }

  /// Tries each of a short list of well-known default MIFARE Classic keys
  /// (as key A) against [sector], succeeding on the first that works.
  ///
  /// Throws [MifareAuthException] if none of them work.
  Future<void> authenticateWithDefaultKeys(int sector) async {
    for (final keyHex in _defaultKeysHex) {
      try {
        await authenticate(
          sector,
          MifareKeyType.a,
          Uint8List.fromList(hex.decode(keyHex)),
        );
        return;
      } on MifareAuthException {
        continue;
      }
    }
    throw MifareAuthException(
      'None of the default keys authenticated sector $sector',
    );
  }

  /// Reads one 16-byte block. The block's sector must already be
  /// authenticated via [authenticate] or [authenticateWithDefaultKeys].
  Future<Uint8List> readBlock(int block) {
    final blockHex = block.toRadixString(16).padLeft(2, '0');
    return transceiveChecked(card, 'FFB000${blockHex}10');
  }

  /// Reads every block in [sector] (4 blocks on a 1K/4K tag). The sector
  /// must already be authenticated.
  Future<List<Uint8List>> readSector(int sector) async {
    final firstBlock = _blockForSector(sector);
    final blocks = <Uint8List>[];
    for (var block = firstBlock; block < firstBlock + 4; block++) {
      blocks.add(await readBlock(block));
    }
    return blocks;
  }

  /// A generic identification summary using the real SAK/ATQA read
  /// directly from the card via a PN532 poll, independent of the ATR.
  @override
  Future<MifareClassicInfo> readTagInfo() async {
    final target = await pollTypeA(card);
    if (target == null) {
      throw Exception('No Type A target found while reading tag info');
    }
    final family = mifareFamilyFromSak(target.sak);
    return MifareClassicInfo(
      technology: mifareFamilyLabel(family),
      uid: target.uid,
      atr: card.atr,
      sak: target.sak,
      atqa: target.atqa,
    );
  }

  int _blockForSector(int sector) => sector * 4;

  Future<void> _loadKey(Uint8List key) async {
    final keyHex = hex.encode(key).toUpperCase();
    final slotHex = _keySlot.toRadixString(16).padLeft(2, '0');
    final capdu = 'FF8200${slotHex}06$keyHex';
    final response = await card.transceive(capdu);
    if (stripAndCheckSw(response) == null) {
      throw MifareAuthException('Failed to load key into reader');
    }
  }

  Future<void> _generalAuthenticate(int block, MifareKeyType keyType) async {
    final blockHex = block.toRadixString(16).padLeft(2, '0');
    final keyTypeHex = keyType == MifareKeyType.a ? '60' : '61';
    final slotHex = _keySlot.toRadixString(16).padLeft(2, '0');
    final capdu = 'FF860000050100$blockHex$keyTypeHex$slotHex';
    final response = await card.transceive(capdu);
    if (stripAndCheckSw(response) == null) {
      throw MifareAuthException('Authentication failed for block $block');
    }
  }
}
