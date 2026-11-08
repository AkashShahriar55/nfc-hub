import 'transport.dart';

/// A source of typed per-technology transports for one tag. Implemented by
/// [CcidTransportBackend] (over a `ReaderCard`) and `AndroidTransportBackend`
/// (over `android.nfc.tech.*`). `identifyFromBackend` builds a driver from
/// whichever transport its tag family needs.
abstract class TransportBackend {
  Type2Transport type2();
  Future<MifareClassicTransport> mifareClassic();
  NfcFTransport nfcF();
  Future<IsoDepTransport> isoDep();
  Future<NfcBTransport?> nfcB();
}

/// A definitive tag-family signal a source can supply to skip probing.
/// The Android source derives this from `Tag.getTechList()`; the CCID
/// source supplies null (it must probe).
enum TagTechHint { type2, mifareClassic, felica, isoDep, typeB }
