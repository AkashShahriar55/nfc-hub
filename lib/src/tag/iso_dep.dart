import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'desfire_info.dart';
import 'tag_driver.dart';
import '../transport/transport.dart';

class IsoDepInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;
  final DesfireVersion? desfireVersion;

  const IsoDepInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.desfireVersion,
  });
}

/// Thin driver for a generic ISO14443-4 ("ISO-DEP") processor card (e.g.
/// DESFire or another applet-based smart card) connected through a
/// contactless PC/SC reader.
///
/// This driver only provides raw ISO 7816-4 SELECT + APDU transport; it has
/// no knowledge of any particular card's application/file model.
class IsoDepTag extends TagDriver {
  final IsoDepTransport transport;

  const IsoDepTag(this.transport);

  /// Sends a SELECT (by name/AID) command for [aidHex] (hex-encoded
  /// Application Identifier), returning the response APDU.
  Future<String?> selectApplication(String aidHex) {
    final lcHex = (aidHex.length ~/ 2).toRadixString(16).padLeft(2, '0');
    return transceive('00A40400$lcHex$aidHex');
  }

  /// Sends a raw APDU [capdu] (hex-encoded) and returns the response APDU
  /// (hex-encoded), unchanged from [transport.transceive].
  Future<String?> transceive(String capdu) async {
    final response =
        await transport.transceive(Uint8List.fromList(hex.decode(capdu)));
    return hex.encode(response).toUpperCase();
  }

  /// A generic identification summary. Attempts a DESFire `GetVersion`
  /// (best-effort -- most non-DESFire ISO14443-4 cards will fail this,
  /// which is expected and doesn't prevent returning the rest of the info).
  @override
  Future<IsoDepInfo> readTagInfo() async {
    final tagUid = await transport.uid;
    DesfireVersion? version;
    try {
      version = await readDesfireVersion();
    } catch (_) {
      // best-effort; leave version null
    }
    final technology = version == null
        ? 'ISO14443-4 (generic)'
        : 'ISO14443-4: ${desfireGenerationLabel(version)}';
    return IsoDepInfo(
      technology: technology,
      uid: tagUid,
      atr: transport.historicalBytes,
      desfireVersion: version,
    );
  }

  /// Reads the card's DESFire `GetVersion` (native command `0x60`),
  /// identifying the exact chip generation. Only valid for DESFire-class
  /// cards; on anything else this will throw or return garbage.
  Future<DesfireVersion> readDesfireVersion() async {
    final hwFrame = await _desfireFrame('60');
    if (hwFrame.isEmpty || hwFrame[0] != 0xAF) {
      throw Exception(
          'Unexpected DESFire GetVersion response (hardware frame): $hwFrame');
    }
    final hw = hwFrame.sublist(1);

    final swFrame = await _desfireFrame('AF');
    if (swFrame.isEmpty || swFrame[0] != 0xAF) {
      throw Exception(
          'Unexpected DESFire GetVersion response (software frame): $swFrame');
    }
    final sw = swFrame.sublist(1);

    final tailFrame = await _desfireFrame('AF');
    if (tailFrame.isEmpty || tailFrame[0] != 0x00) {
      throw Exception(
          'Unexpected DESFire GetVersion response (UID/batch frame): $tailFrame');
    }
    final tail = tailFrame.sublist(1);

    if (hw.length != 7 || sw.length != 7 || tail.length != 14) {
      throw Exception('Malformed DESFire GetVersion frame lengths '
          '(hw=${hw.length}, sw=${sw.length}, tail=${tail.length})');
    }

    return DesfireVersion(
      hardwareVendorId: hw[0],
      hardwareType: hw[1],
      hardwareSubtype: hw[2],
      hardwareMajor: hw[3],
      hardwareMinor: hw[4],
      hardwareStorageSize: hw[5],
      hardwareProtocol: hw[6],
      softwareVendorId: sw[0],
      softwareType: sw[1],
      softwareSubtype: sw[2],
      softwareMajor: sw[3],
      softwareMinor: sw[4],
      softwareStorageSize: sw[5],
      softwareProtocol: sw[6],
      uid: tail.sublist(0, 7),
      batch: tail.sublist(7, 12),
      productionWeek: tail[12],
      productionYear: tail[13],
    );
  }

  /// Sends [capdu] (raw, no ISO7816 wrapping -- DESFire's native mode)
  /// and returns the decoded response bytes. Per ACS's ACR122U
  /// documentation, native-mode DESFire responses of 2+ bytes carry no
  /// appended PC/SC status word at all, unlike every other read in this
  /// plugin -- the full response already IS the data, with byte 0
  /// carrying DESFire's own continuation status (`0xAF` = more frames,
  /// `0x00` = last frame) instead of an ISO status word.
  Future<Uint8List> _desfireFrame(String capdu) async {
    final response =
        await transport.transceive(Uint8List.fromList(hex.decode(capdu)));
    if (response.isEmpty) {
      throw Exception('No response to DESFire command $capdu');
    }
    return response;
  }
}
