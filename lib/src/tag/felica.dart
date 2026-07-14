import 'dart:typed_data';

import 'felica_info.dart';
import 'tag_driver.dart';
import '../transport/transport.dart';

/// The parsed result of a FeliCa "Read Without Encryption" command.
class FelicaReadResult {
  final int statusFlag1;
  final int statusFlag2;
  final List<Uint8List> blocks;

  const FelicaReadResult({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.blocks,
  });

  /// Whether the card reported success (both status flags zero).
  bool get isSuccess => statusFlag1 == 0x00 && statusFlag2 == 0x00;
}

class FelicaInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid; // IDm
  @override
  final Uint8List? atr;
  final Uint8List pmm;
  final String? modelName;
  final List<int> systemCodes;

  const FelicaInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.pmm,
    required this.modelName,
    required this.systemCodes,
  });
}

/// Driver for a FeliCa (NFC-F / JIS X 6319-4) tag.
///
/// FeliCa's command framing isn't ISO 7816 APDUs; frames are raw
/// length-prefixed FeliCa commands, handed to [transport] which owns
/// whatever reader-specific dialect getting them to the card requires (on
/// CCID, the PN532 InDataExchange escape wrapping).
class FelicaTag extends TagDriver {
  final NfcFTransport transport;

  /// The card's ATR, where the source supplies one. Null on sources that
  /// have no ATR concept (the device's built-in NFC antenna).
  final Uint8List? atr;

  const FelicaTag(this.transport, {this.atr});

  /// The card's 8-byte IDm.
  Future<Uint8List> get idm => transport.idm;

  /// The card's 8-byte PMm (Manufacturer Parameter). PMm's first two bytes
  /// (ROM Type, IC Type) identify the chip model -- see [felicaModelName]
  /// in `felica_info.dart`.
  Future<Uint8List> get pmm => transport.pmm;

  /// A generic identification summary: IDm, PMm-derived chip model
  /// (community-sourced -- see [felicaModelName]), and every System Code
  /// on the card (best-effort -- a failure here doesn't prevent returning
  /// the rest of the info).
  @override
  Future<FelicaInfo> readTagInfo() async {
    final cardIdm = await idm;
    final cardPmm = await pmm;
    final model = felicaModelName(cardPmm);
    var systemCodes = <int>[];
    try {
      systemCodes = await requestSystemCodes();
    } catch (_) {
      // best-effort; leave systemCodes empty
    }
    return FelicaInfo(
      technology: model == null ? 'FeliCa' : 'FeliCa ($model)',
      uid: cardIdm,
      atr: atr,
      pmm: cardPmm,
      modelName: model,
      systemCodes: systemCodes,
    );
  }

  /// Sends a FeliCa "Read Without Encryption" (command code 0x06) for
  /// [serviceCode], reading each block number in [blockList].
  ///
  /// Each block list entry must be 0-255 (2-byte block list element form).
  Future<FelicaReadResult> readWithoutEncryption(
    int serviceCode,
    List<int> blockList,
  ) async {
    final cardIdm = await idm;
    final frame = BytesBuilder();
    frame.addByte(0x06); // command code
    frame.add(cardIdm);
    frame.addByte(0x01); // number of service codes
    frame.addByte(serviceCode & 0xFF); // service code, little-endian
    frame.addByte((serviceCode >> 8) & 0xFF);
    frame.addByte(blockList.length);
    for (final block in blockList) {
      frame.addByte(0x80); // 2-byte block list element
      frame.addByte(block & 0xFF);
    }
    final response = await transport.transceive(frame.toBytes());

    // Response frame: length(1) | responseCode(1)=0x07 | idm(8) | SF1(1) |
    // SF2(1) | numBlocks(1) | blocks(16 bytes each).
    if (response.length < 12) {
      throw Exception(
          'FeliCa read response too short (${response.length} bytes)');
    }
    final statusFlag1 = response[10];
    final statusFlag2 = response[11];
    final blocks = <Uint8List>[];
    if (statusFlag1 == 0x00 && statusFlag2 == 0x00) {
      final numBlocks = response.length > 12 ? response[12] : 0;
      var offset = 13;
      for (var i = 0; i < numBlocks && offset + 16 <= response.length; i++) {
        blocks.add(Uint8List.sublistView(response, offset, offset + 16));
        offset += 16;
      }
    }
    return FelicaReadResult(
      statusFlag1: statusFlag1,
      statusFlag2: statusFlag2,
      blocks: blocks,
    );
  }

  /// Enumerates every System Code present on the card via the native
  /// "Request System Code" command (`0x0C`), not just whichever System a
  /// specific service-code read happens to target.
  Future<List<int>> requestSystemCodes() async {
    final cardIdm = await idm;
    final response =
        await transport.transceive(Uint8List.fromList([0x0C, ...cardIdm]));
    // Response frame: length(1) | responseCode(1)=0x0D | idm(8) |
    // numSystems(1) | systemCode(2) x numSystems.
    if (response.length < 11) {
      throw Exception('Request System Code response too short '
          '(${response.length} bytes)');
    }
    final numSystems = response[10];
    final systemCodes = <int>[];
    var offset = 11;
    for (var i = 0; i < numSystems && offset + 2 <= response.length; i++) {
      systemCodes.add((response[offset] << 8) | response[offset + 1]);
      offset += 2;
    }
    return systemCodes;
  }
}
