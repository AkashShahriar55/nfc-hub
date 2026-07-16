/// nfc_hub — read NFC tags through external CCID readers or (from Plan 3)
/// the device's built-in NFC antenna, behind one API.
library;

export 'src/nfc_hub_api.dart'
    show CcidSourceFilter, CcidConnectionState, NfcUnavailableReason;
export 'src/nfc_hub_base.dart' show NfcHub, CcidCard;
export 'src/nfc_hub_reader.dart'
    show NfcHubReader, NfcTag, NfcConnectionState, NfcSource;
export 'src/ndef.dart' show NdefRecord, parseNdefRecords, parseTlvForNdefMessage;
export 'src/platform/platform_interface.dart' show NfcHubPlatform;
export 'src/source/ccid_source.dart' show ExternalReaderState;
export 'src/tag/detection.dart' show identifyTag, identifyFromBackend;
export 'src/tag/desfire_info.dart' show DesfireVersion, desfireGenerationLabel;
export 'src/tag/felica.dart' show FelicaInfo, FelicaTag, FelicaReadResult;
export 'src/tag/felica_info.dart' show felicaModelName, felicaSystemCodeLabel;
export 'src/tag/iso_b.dart' show TypeBInfo, TypeBTag;
export 'src/tag/iso_dep.dart' show IsoDepInfo, IsoDepTag;
export 'src/tag/mifare_classic.dart'
    show MifareClassicInfo, MifareClassicTag, MifareKeyType, MifareAuthException;
export 'src/tag/mifare_info.dart'
    show MifareFamily, mifareFamilyFromSak, mifareFamilyLabel;
export 'src/tag/tag_driver.dart' show TagDriver, TagInfo, UnrecognizedTagException;
export 'src/tag/tag_info.dart' show CapabilityContainer, ChipVersion, ultralightModelName;
export 'src/tag/type2.dart' show Type2Tag, Type2TagInfo;
export 'src/transport/backend.dart' show TransportBackend, TagTechHint;
export 'src/transport/transport.dart'
    show
        TagLostException,
        Type2Transport,
        MifareClassicTransport,
        NfcFTransport,
        IsoDepTransport,
        NfcBTransport;
