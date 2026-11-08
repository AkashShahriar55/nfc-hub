import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'mifare_info.dart';
import 'tag_driver.dart';
import '../transport/transport.dart';

/// Which MIFARE Classic key slot (A or B) to authenticate with.
enum MifareKeyType {
  /// MIFARE key A.
  a,

  /// MIFARE key B.
  b,
}

/// Thrown by [MifareClassicTag] authentication methods when a key is
/// rejected by the card. This is an expected, catchable outcome (wrong key
/// or wrong sector), not a bug.
class MifareAuthException implements Exception {
  /// A description of the failure.
  final String message;

  /// Creates an exception with [message].
  const MifareAuthException(this.message);

  @override
  String toString() => 'MifareAuthException: $message';
}

/// Identification details for a MIFARE Classic tag.
class MifareClassicInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;

  /// The card's SAK byte.
  final int sak;

  /// The card's ATQA bytes.
  final Uint8List atqa;

  /// Creates an info record from its decoded fields.
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
/// cipher itself; this driver only calls into [transport], which sends the
/// PC/SC "Load Keys" and "General Authenticate" pseudo-APDUs (PC/SC Part 3)
/// on CCID.
class MifareClassicTag extends TagDriver {
  /// The transport used to reach this tag.
  final MifareClassicTransport transport;

  /// The card's ATR, where the source supplies one. Null on sources that
  /// have no ATR concept (the device's built-in NFC antenna).
  final Uint8List? atr;

  /// Creates a driver over [transport].
  ///
  /// Apps receive drivers from nfc_hub rather than constructing them.
  const MifareClassicTag(this.transport, {this.atr});

  static const List<String> _defaultKeysHex = [
    'FFFFFFFFFFFF',
    'A0A1A2A3A4A5',
    'D3F7D3F7D3F7',
    '000000000000',
  ];

  /// Loads [key] (6 bytes) into the reader and authenticates [sector] with
  /// it as key [keyType].
  ///
  /// Throws [MifareAuthException] if the key is rejected.
  Future<void> authenticate(
    int sector,
    MifareKeyType keyType,
    Uint8List key,
  ) =>
      transport.authenticate(sector, keyType, key);

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
  Future<Uint8List> readBlock(int block) => transport.readBlock(block);

  /// Reads every block in [sector] (4 blocks on a 1K/4K tag). The sector
  /// must already be authenticated.
  ///
  /// KNOWN LIMITATION: this assumes 4 blocks per sector, which is wrong for
  /// MIFARE Classic 4K sectors 32-39 (16 blocks each) -- those sectors will
  /// read the wrong block range. Pre-existing; not fixed here, see
  /// [MifareClassicTransport.authenticate] for the matching arithmetic.
  Future<List<Uint8List>> readSector(int sector) async {
    final firstBlock = sector * 4;
    final blocks = <Uint8List>[];
    for (var block = firstBlock; block < firstBlock + 4; block++) {
      blocks.add(await readBlock(block));
    }
    return blocks;
  }

  /// A generic identification summary using the real SAK/ATQA/UID the
  /// transport already carries from the poll it performed when it was
  /// built.
  @override
  Future<MifareClassicInfo> readTagInfo() async {
    final family = mifareFamilyFromSak(transport.sak);
    return MifareClassicInfo(
      technology: mifareFamilyLabel(family),
      uid: transport.uid,
      atr: atr,
      sak: transport.sak,
      atqa: transport.atqa,
    );
  }
}
