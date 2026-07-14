/// nfc_hub — read NFC tags through external CCID readers or (from Plan 3)
/// the device's built-in NFC antenna, behind one API.
library;

export 'src/nfc_hub_base.dart' show Ccid, CcidCard;
export 'src/ndef.dart' show NdefRecord;
export 'src/tag/detection.dart' show identifyTag;
export 'src/tag/desfire_info.dart' show DesfireVersion;
export 'src/tag/felica.dart' show FelicaInfo, FelicaTag, FelicaReadResult;
export 'src/tag/felica_info.dart' show felicaSystemCodeLabel;
export 'src/tag/iso_b.dart' show TypeBInfo, TypeBTag;
export 'src/tag/iso_dep.dart' show IsoDepInfo, IsoDepTag;
export 'src/tag/mifare_classic.dart'
    show MifareClassicInfo, MifareClassicTag, MifareKeyType, MifareAuthException;
export 'src/tag/tag_driver.dart' show TagDriver, TagInfo, UnrecognizedTagException;
export 'src/tag/tag_info.dart' show CapabilityContainer, ChipVersion;
export 'src/tag/type2.dart' show Type2Tag, Type2TagInfo;
