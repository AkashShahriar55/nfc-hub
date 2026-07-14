import 'dart:typed_data';

import 'package:convert/convert.dart';

import '../apdu.dart';
import '../nfc_hub_base.dart';
import '../pn532.dart';
import '../tag/mifare_classic.dart' show MifareKeyType, MifareAuthException;
import 'transport.dart';

/// Builds typed transports over a card connected through a CCID / PC-SC
/// reader. This is the ONLY place the ACR122U's PC/SC pseudo-APDU and
/// PN532 escape dialect lives; drivers above it are transport-agnostic.
class CcidTransportBackend {
  final CcidCard card;

  CcidTransportBackend(this.card);

  Type2Transport type2() => _CcidType2Transport(card);

  NfcFTransport nfcF() => _CcidNfcFTransport(card);

  /// Async: must poll the card (PN532 InListPassiveTarget) for ATQA/SAK/UID.
  Future<MifareClassicTransport> mifareClassic() async {
    final target = await pollTypeA(card);
    if (target == null) {
      throw const TagLostException('No Type A target answered the poll');
    }
    return _CcidMifareClassicTransport(card, target);
  }

  /// Async: polls for the UID. The poll is best-effort -- it rides on the
  /// PN532 escape command, which a generic (non-ACS) CCID reader may not
  /// implement at all. A reader that cannot poll still gets a working
  /// ISO-DEP driver; only the UID is unavailable. ISO 7816-4 APDUs need no
  /// reader-specific dialect, so ISO-DEP must work on ANY CCID reader.
  Future<IsoDepTransport> isoDep() async {
    Uint8List uid;
    try {
      final target = await pollTypeA(card);
      uid = target?.uid ?? Uint8List(0);
    } catch (_) {
      uid = Uint8List(0);
    }
    return _CcidIsoDepTransport(card, uid);
  }

  /// Null if no Type B target answers.
  Future<NfcBTransport?> nfcB() async {
    final target = await pollTypeB(card);
    if (target == null) return null;
    return _CcidNfcBTransport(card, target.atqb);
  }
}

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0');

class _CcidType2Transport implements Type2Transport {
  final CcidCard card;

  _CcidType2Transport(this.card);

  @override
  Future<Uint8List> readUid() => transceiveChecked(card, 'FFCA000000');

  @override
  Future<Uint8List> readCapabilityContainer() async {
    final bytes = await transceiveChecked(card, 'FFB0000304');
    if (bytes.length != 4) {
      throw Exception('Failed to read Capability Container (expected 4 '
          'bytes, got ${bytes.length})');
    }
    return bytes;
  }

  @override
  Future<Uint8List> readPages(int startPage) =>
      transceiveChecked(card, 'FFB000${_hex2(startPage)}10');

  @override
  Future<Uint8List?> getVersion() async {
    try {
      final data = stripAndCheckSw(await card.transceive('FF0000000160'));
      if (data == null || data.length != 8) return null;
      return data;
    } catch (_) {
      return null;
    }
  }
}

class _CcidMifareClassicTransport implements MifareClassicTransport {
  final CcidCard card;
  final PassiveTargetTypeA target;

  static const int _keySlot = 0x00;

  _CcidMifareClassicTransport(this.card, this.target);

  @override
  Uint8List get uid => target.uid;

  @override
  Uint8List get atqa => target.atqa;

  @override
  int get sak => target.sak;

  @override
  Future<void> authenticate(
      int sector, MifareKeyType type, Uint8List key) async {
    if (key.length != 6) {
      throw ArgumentError('MIFARE Classic keys are 6 bytes, got ${key.length}');
    }
    final keyHex = hex.encode(key).toUpperCase();
    final slotHex = _hex2(_keySlot);
    final loadResponse = await card.transceive('FF8200${slotHex}06$keyHex');
    if (stripAndCheckSw(loadResponse) == null) {
      throw const MifareAuthException('Failed to load key into reader');
    }

    final block = sector * 4;
    final blockHex = _hex2(block);
    final keyTypeHex = type == MifareKeyType.a ? '60' : '61';
    final authResponse =
        await card.transceive('FF860000050100$blockHex$keyTypeHex$slotHex');
    if (stripAndCheckSw(authResponse) == null) {
      throw MifareAuthException('Authentication failed for block $block');
    }
  }

  @override
  Future<Uint8List> readBlock(int block) =>
      transceiveChecked(card, 'FFB000${_hex2(block)}10');
}

class _CcidNfcFTransport implements NfcFTransport {
  final CcidCard card;

  Uint8List? _idm;
  Uint8List? _pmm;

  _CcidNfcFTransport(this.card);

  @override
  Future<Uint8List> get idm async {
    final cached = _idm;
    if (cached != null) return cached;
    final read = await transceiveChecked(card, 'FFCA000000');
    _idm = read;
    return read;
  }

  @override
  Future<Uint8List> get pmm async {
    final cached = _pmm;
    if (cached != null) return cached;
    final response = await transceive(Uint8List.fromList([
      0x00, // Polling
      0xFF, 0xFF, // wildcard system code
      0x00, // request code: none
      0x00, // time slot
    ]));
    // length(1) | responseCode(1)=0x01 | idm(8) | pmm(8)
    if (response.length < 18) {
      throw Exception(
          'FeliCa polling response too short (${response.length} bytes)');
    }
    final read = Uint8List.sublistView(response, 10, 18);
    _pmm = read;
    return read;
  }

  @override
  Future<Uint8List> transceive(Uint8List felicaFrame) async {
    final framed =
        Uint8List.fromList([felicaFrame.length + 1, ...felicaFrame]);
    final payload = Uint8List.fromList([0xD4, 0x40, 0x01, ...framed]);

    final response = await transceiveEscape(card, payload);
    if (response.length < 3 || response[0] != 0xD5 || response[1] != 0x41) {
      throw Exception(
          'Unexpected InDataExchange response header: ${hex.encode(response)}');
    }
    if (response[2] != 0x00) {
      throw Exception('InDataExchange failed with status '
          '0x${_hex2(response[2])}');
    }
    return Uint8List.sublistView(response, 3);
  }
}

class _CcidIsoDepTransport implements IsoDepTransport {
  final CcidCard card;
  final Uint8List _uid;

  _CcidIsoDepTransport(this.card, this._uid);

  @override
  Future<Uint8List> get uid async => _uid;

  @override
  Uint8List? get historicalBytes => card.atr;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final responseHex = await card.transceive(hex.encode(apdu).toUpperCase());
    if (responseHex == null || responseHex.isEmpty) {
      throw Exception('No response to APDU ${hex.encode(apdu)}');
    }
    return Uint8List.fromList(hex.decode(responseHex));
  }
}

class _CcidNfcBTransport implements NfcBTransport {
  final CcidCard card;

  @override
  final Uint8List atqb;

  _CcidNfcBTransport(this.card, this.atqb);

  @override
  Uint8List get pupi => Uint8List.sublistView(atqb, 1, 5);

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final responseHex = await card.transceive(hex.encode(apdu).toUpperCase());
    if (responseHex == null || responseHex.isEmpty) {
      throw Exception('No response to APDU ${hex.encode(apdu)}');
    }
    return Uint8List.fromList(hex.decode(responseHex));
  }
}
