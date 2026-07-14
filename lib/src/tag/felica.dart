import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'felica_info.dart';
import 'tag_driver.dart';
import '../apdu.dart';

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

/// Driver for a FeliCa (NFC-F / JIS X 6319-4) tag connected through a
/// contactless PC/SC reader.
///
/// FeliCa's command framing isn't ISO 7816 APDUs, so reads go through the
/// reader's PN532-based direct-transmit escape command, wrapped as a PN532
/// "InDataExchange" native command (`D4 40 01`, targeting target #1 — the
/// card already selected by the reader's own continuous PICC polling) per
/// ACS's ACR122U NFC Reader API (section 7.3, "How to Access FeliCa
/// Tags"): `FF 00 00 00 <Lc> D4 40 01 <FeliCa command>`, response
/// `D5 41 <status> <FeliCa response>`.
class FelicaTag extends TagDriver {
  FelicaTag(super.card);

  Uint8List? _idm;
  Uint8List? _pmm;

  /// The card's 8-byte IDm, read once via the reader's standard PC/SC
  /// "Get Data" pseudo-APDU (`FF CA 00 00 00`) — which returns the FeliCa
  /// IDm on this class of reader, per ACS's documentation — and cached for
  /// the lifetime of this driver.
  Future<Uint8List> get idm async {
    final cached = _idm;
    if (cached != null) return cached;
    final read = await transceiveChecked(card, 'FFCA000000');
    _idm = read;
    return read;
  }

  /// The card's 8-byte PMm (Manufacturer Parameter), read once via a
  /// FeliCa Polling (SENSF_REQ) command sent through the same
  /// InDataExchange-wrapped escape command `readWithoutEncryption` uses,
  /// and cached for the lifetime of this driver. PMm's first two bytes
  /// (ROM Type, IC Type) identify the chip model — see
  /// [felicaModelName] in `felica_info.dart`.
  Future<Uint8List> get pmm async {
    final cached = _pmm;
    if (cached != null) return cached;
    final command = Uint8List.fromList([
      0x00, // Polling command code
      0xFF, 0xFF, // System Code: wildcard
      0x00, // Request Code: none
      0x00, // Time Slot
    ]);
    final response = await _transceiveFelicaFrame(command);
    // Response frame: length(1) | responseCode(1)=0x01 | idm(8) | pmm(8).
    if (response.length < 18) {
      throw Exception(
          'FeliCa polling response too short (${response.length} bytes)');
    }
    final read = Uint8List.sublistView(response, 10, 18);
    _pmm = read;
    return read;
  }

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
      atr: card.atr,
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
    final response = await _transceiveFelicaFrame(frame.toBytes());

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
    final command = Uint8List.fromList([0x0C, ...cardIdm]);
    final response = await _transceiveFelicaFrame(command);
    // Response frame: length(1) | responseCode(1)=0x0D | idm(8) |
    // numSystems(1) | systemCode(2) x numSystems.
    if (response.length < 11) {
      throw Exception('Request System Code response too short '
          '(${response.length} bytes)');
    }
    final numSystems = response[10];
    final systemCodes = <int>[];
    var offset = 11;
    for (var i = 0;
        i < numSystems && offset + 2 <= response.length;
        i++) {
      systemCodes.add((response[offset] << 8) | response[offset + 1]);
      offset += 2;
    }
    return systemCodes;
  }

  /// Wraps [felicaCommand] in its own length-prefix byte, then in the
  /// PN532 InDataExchange native command (`D4 40 01`), and sends the whole
  /// thing via the reader's direct-transmit escape pseudo-APDU
  /// (`FF 00 00 00 <Lc> <data>`). Strips the `D5 41 <status>`
  /// InDataExchange response header and returns the raw FeliCa response
  /// frame (length byte included).
  Future<Uint8List> _transceiveFelicaFrame(Uint8List felicaCommand) async {
    final framedFelicaCommand =
        Uint8List.fromList([felicaCommand.length + 1, ...felicaCommand]);
    final payload =
        Uint8List.fromList([0xD4, 0x40, 0x01, ...framedFelicaCommand]);

    final response = await transceiveEscape(card, payload);
    if (response.length < 3 || response[0] != 0xD5 || response[1] != 0x41) {
      throw Exception(
          'Unexpected InDataExchange response header: ${hex.encode(response)}');
    }
    if (response[2] != 0x00) {
      throw Exception('InDataExchange failed with status '
          '0x${response[2].toRadixString(16).padLeft(2, '0')}');
    }
    return Uint8List.sublistView(response, 3);
  }
}
