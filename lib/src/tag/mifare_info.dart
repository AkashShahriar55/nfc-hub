/// The coarse MIFARE-family classification of a card, resolved from its
/// SAK (Select Acknowledge) byte per NXP's AN10833 "MIFARE Type
/// Identification Procedure". ATQA is deliberately not used for branching
/// here -- NXP's own guidance is that ATQA can be misleading and SAK is
/// the authoritative discriminator.
enum MifareFamily {
  classic1k,
  classic4k,
  mini,
  ultralightOrNtag,
  desfireOrPlusSl3,
  unknown,
}

/// Resolves the [MifareFamily] for [sak]. Bit `0x20` (ISO14443-4
/// compliance) is checked first, since DESFire/Plus-SL3 cards can present
/// it combined with other bits.
MifareFamily mifareFamilyFromSak(int sak) {
  if (sak & 0x20 != 0) return MifareFamily.desfireOrPlusSl3;
  switch (sak) {
    case 0x08:
      return MifareFamily.classic1k;
    case 0x18:
      return MifareFamily.classic4k;
    case 0x09:
      return MifareFamily.mini;
    case 0x00:
      return MifareFamily.ultralightOrNtag;
    default:
      return MifareFamily.unknown;
  }
}

/// A human-readable label for [family].
String mifareFamilyLabel(MifareFamily family) {
  switch (family) {
    case MifareFamily.classic1k:
      return 'MIFARE Classic 1K';
    case MifareFamily.classic4k:
      return 'MIFARE Classic 4K';
    case MifareFamily.mini:
      return 'MIFARE Mini';
    case MifareFamily.ultralightOrNtag:
      return 'MIFARE Ultralight / NTAG family';
    case MifareFamily.desfireOrPlusSl3:
      return 'MIFARE DESFire / MIFARE Plus (SL3)';
    case MifareFamily.unknown:
      return 'Unknown MIFARE-family card (SAK not recognized)';
  }
}
