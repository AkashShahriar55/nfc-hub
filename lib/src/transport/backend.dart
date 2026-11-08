import 'transport.dart';

/// A source of typed per-technology transports for one tag. Implemented by
/// `CcidTransportBackend` (over a `ReaderCard`) and `AndroidTransportBackend`
/// (over `android.nfc.tech.*`). `identifyFromBackend` builds a driver from
/// whichever transport its tag family needs.
abstract class TransportBackend {
  /// Returns the transport for Type 2 tags.
  Type2Transport type2();

  /// Returns the transport for MIFARE Classic tags.
  Future<MifareClassicTransport> mifareClassic();

  /// Returns the transport for FeliCa tags.
  NfcFTransport nfcF();

  /// Returns the transport for ISO-DEP tags.
  Future<IsoDepTransport> isoDep();

  /// Returns the transport for ISO 14443-B tags, or null if none is present.
  Future<NfcBTransport?> nfcB();
}

/// A definitive tag-family signal a source can supply to skip probing.
/// The Android source derives this from `Tag.getTechList()`; the CCID
/// source supplies null (it must probe).
enum TagTechHint {
  /// An NFC Forum Type 2 tag.
  type2,

  /// A MIFARE Classic tag.
  mifareClassic,

  /// A FeliCa tag.
  felica,

  /// An ISO-DEP tag.
  isoDep,

  /// An ISO 14443-B tag.
  typeB,
}
