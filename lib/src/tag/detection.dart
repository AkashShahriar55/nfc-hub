import 'dart:typed_data';

import 'package:convert/convert.dart';

import '../nfc_hub_base.dart' show CcidCard;
import '../transport/backend.dart';
import '../transport/ccid_backend.dart';
import 'felica.dart';
import 'iso_b.dart';
import 'iso_dep.dart';
import 'mifare_classic.dart';
import 'tag_driver.dart';
import 'type2.dart';
import '../apdu.dart';

/// Identifies the tag family of the card connected through [card] and
/// returns the matching typed driver.
///
/// Uses [CcidCard.atr] where available (see PC/SC Part 3's historical-byte
/// markers for contactless storage cards). Where [CcidCard.atr] is null or
/// doesn't match a known pattern, falls back to ordered capability probing.
///
/// Throws [UnrecognizedTagException] if no known tag family matches. The
/// exception's message includes the ATR (if any) and the outcome of every
/// probe that was tried, so a caller displaying `toString()` on-screen has
/// enough to diagnose a detection failure without separate log access.
Future<TagDriver> identifyTag(CcidCard card) async {
  return identifyFromBackend(CcidTransportBackend(card), atr: card.atr);
}

/// Identifies the tag family reachable through [backend] and returns the
/// matching typed driver.
///
/// With a non-null [hint], the caller already knows the tag family (e.g.
/// the Android source derives it from `Tag.getTechList()`) and the matching
/// driver is built directly -- no ATR match, no probing.
///
/// With a null [hint], runs the existing ATR-match -> probing chain. That
/// path is CCID-specific (probing sends PC/SC pseudo-APDUs), so [backend]
/// must be a [CcidTransportBackend] in that case.
Future<TagDriver> identifyFromBackend(
  TransportBackend backend, {
  Uint8List? atr,
  TagTechHint? hint,
}) async {
  if (hint != null) {
    switch (hint) {
      case TagTechHint.type2:
        return Type2Tag(backend.type2(), atr: atr);
      case TagTechHint.mifareClassic:
        return MifareClassicTag(await backend.mifareClassic(), atr: atr);
      case TagTechHint.felica:
        return FelicaTag(backend.nfcF(), atr: atr);
      case TagTechHint.isoDep:
        return IsoDepTag(await backend.isoDep());
      case TagTechHint.typeB:
        final nfcB = await backend.nfcB();
        if (nfcB == null) {
          throw const UnrecognizedTagException(
              'Type B hinted but no Type B target present');
        }
        return TypeBTag(nfcB, atr: atr);
    }
  }

  // Null-hint identification requires probing, which is CCID-specific.
  if (backend is! CcidTransportBackend) {
    throw ArgumentError(
        'identifyFromBackend without a hint requires a CcidTransportBackend '
        '(probing uses PC/SC pseudo-APDUs). Android sources must pass a hint.');
  }
  final card = backend.card;
  final atrToUse = atr;
  if (atrToUse != null) {
    final fromAtr = await _identifyFromAtr(card, backend, atrToUse);
    if (fromAtr != null) return fromAtr;
  }
  return _identifyByProbing(card, backend, atrToUse);
}

Future<TagDriver?> _identifyFromAtr(
    CcidCard card, CcidTransportBackend backend, Uint8List atr) async {
  if (atr.length < 5) return null;
  final historicalBytes = atr.sublist(4);

  // The PC/SC Part 3 RID A0 00 00 03 06 is shared by every T=CL-emulated
  // contactless storage card family (MIFARE Classic, Type 2/Ultralight,
  // and FeliCa all carry it). Per ACS's ACR122U NFC Reader API (section
  // 3.1.1), the byte immediately after the RID ("standard") is *always*
  // 0x03 for these families — the real discriminator is a 2-byte "card
  // name" field (C0, C1) starting one byte after that:
  //   C0=0x00, C1=0x01 or 0x02 -> MIFARE Classic (1K/4K)
  //   C0=0x00, C1=0x03         -> Type 2 (NTAG/Ultralight)
  //   C0=0xF0, C1=0x11 or 0x12 -> FeliCa (212K/424K)
  // Example FeliCa ATR from the same document: 3B 8F 80 01 80 4F 0C
  // A0 00 00 03 06 03 F0 11 00 00 00 00 8A.
  final ridIndex = _indexOf(historicalBytes, [0xA0, 0x00, 0x00, 0x03, 0x06]);
  if (ridIndex != null) {
    final standardIndex = ridIndex + 5;
    final c0Index = standardIndex + 1;
    final c1Index = standardIndex + 2;
    if (c1Index < historicalBytes.length &&
        historicalBytes[standardIndex] == 0x03) {
      final c0 = historicalBytes[c0Index];
      final c1 = historicalBytes[c1Index];
      if (c0 == 0x00 && (c1 == 0x01 || c1 == 0x02)) {
        // The ATR is the stronger signal here: CcidTransportBackend.
        // mifareClassic() never throws (the PN532 identity poll is
        // best-effort and degrades to an empty uid/atqa/sak=0 on its own),
        // so there is nothing left to catch and no reason to fall through
        // to capability probing.
        return MifareClassicTag(await backend.mifareClassic(), atr: atr);
      }
      if (c0 == 0x00 && c1 == 0x03) {
        return Type2Tag(backend.type2(), atr: atr);
      }
      if (c0 == 0xF0 && (c1 == 0x11 || c1 == 0x12)) {
        return FelicaTag(backend.nfcF(), atr: atr);
      }
    }
  }

  // Weaker fallback heuristics, used only when the RID-based discrimination
  // above didn't produce a match (RID absent entirely, or its trailing
  // bytes were missing/unrecognized).
  if (historicalBytes.contains(0x11)) {
    return FelicaTag(backend.nfcF(), atr: atr);
  }
  if (historicalBytes.contains(0x03)) {
    return Type2Tag(backend.type2(), atr: atr);
  }
  // A real ATS-derived ATR (not a PC/SC Part 3 synchronous-card pseudo-ATR)
  // with none of the above markers: treat as a generic processor card.
  return IsoDepTag(await backend.isoDep());
}

/// Returns the index at which [needle] first occurs in [haystack], or null
/// if it doesn't occur at all.
int? _indexOf(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return null;
}

Future<String?> _tryTransceive(CcidCard card, String capdu) async {
  try {
    return await card.transceive(capdu);
  } catch (_) {
    return null;
  }
}

/// Tries every known tag family's probe in turn and returns the first
/// match. Every probe's outcome is recorded in [log] regardless of whether
/// it matched, so that if nothing matches, [UnrecognizedTagException] can
/// report exactly what was tried and what each probe returned.
///
/// No single probe gates the others: a card not answering the Get UID
/// pseudo-APDU (built for ISO14443-A) doesn't stop the MIFARE or FeliCa
/// probes from running, since FeliCa in particular is a different RF
/// technology (NFC-F) that isn't expected to answer it.
Future<TagDriver> _identifyByProbing(
    CcidCard card, CcidTransportBackend backend, Uint8List? atr) async {
  final log = <String>[
    atr == null ? 'atr=none' : 'atr=${hex.encode(atr)} (no known pattern)',
  ];

  final uidResponse = await _tryTransceive(card, 'FFCA000000');
  log.add('Get UID -> ${uidResponse ?? 'no response'}');

  final ccResponse = await _tryTransceive(card, 'FFB0000304');
  final ccData = stripAndCheckSw(ccResponse);
  log.add('Read CC -> ${ccResponse ?? 'no response'}');
  if (ccData != null && ccData.length == 4 && ccData[0] == 0xE1) {
    return Type2Tag(backend.type2(), atr: atr);
  }

  final selectResponse = await _tryTransceive(card, '00A4040000');
  log.add('SELECT -> ${selectResponse ?? 'no response'}');
  if (selectResponse != null && selectResponse.length >= 4) {
    return IsoDepTag(await backend.isoDep());
  }

  try {
    final mifare = MifareClassicTag(await backend.mifareClassic(), atr: atr);
    await mifare.authenticateWithDefaultKeys(0);
    return mifare;
  } catch (e) {
    log.add('MIFARE default-key auth -> failed: $e');
  }

  final felica = FelicaTag(backend.nfcF(), atr: atr);
  try {
    final idm = await felica.idm;
    log.add('FeliCa idm -> succeeded, idm=${hex.encode(idm)}');
    return felica;
  } catch (e) {
    log.add('FeliCa idm -> failed: $e');
  }

  try {
    final nfcB = await backend.nfcB();
    if (nfcB != null) {
      log.add('Type B poll -> succeeded, atqb=${hex.encode(nfcB.atqb)}');
      return TypeBTag(nfcB, atr: atr);
    }
    log.add('Type B poll -> no target found');
  } catch (e) {
    log.add('Type B poll -> failed: $e');
  }

  throw UnrecognizedTagException(
    'Card did not match any known tag family (Type 2, MIFARE Classic, '
    'FeliCa, ISO-DEP, or ISO14443-B). ${log.join('; ')}',
  );
}
