import 'package:flutter/services.dart';

import '../platform/android_nfc_manager.dart';
import '../tag/mifare_classic.dart' show MifareKeyType, MifareAuthException;
import 'backend.dart';
import 'transport.dart';

/// Builds typed transports over a tag discovered by the phone's built-in NFC
/// antenna, addressed through [AndroidNfcManager] by the discovery's opaque
/// [NfcTagDiscovery.handle]. This is the native counterpart to
/// `CcidTransportBackend`: it implements the exact same five transport
/// interfaces, so drivers built on top of them are source-agnostic. This is
/// the ONLY place the Android `android.nfc.tech.*` byte formats live.
///
/// Identity fields (uid/atqa/sak/idm/pmm/pupi/atqb/historicalBytes) all come
/// from [discovery], which is populated at tap time by the platform side --
/// none of the identity getters below perform any I/O. Only actual reads
/// (`transceive`, `authenticate`, `readBlock`) call into [manager].
class AndroidTransportBackend implements TransportBackend {
  final AndroidNfcManager manager;
  final NfcTagDiscovery discovery;

  AndroidTransportBackend(this.manager, this.discovery);

  @override
  Type2Transport type2() =>
      _AndroidType2Transport(manager, discovery.handle, discovery);

  @override
  NfcFTransport nfcF() =>
      _AndroidNfcFTransport(manager, discovery.handle, discovery);

  /// Async only to match [TransportBackend]'s signature -- no poll is
  /// needed, the identity fields are already in [discovery].
  @override
  Future<MifareClassicTransport> mifareClassic() => Future.value(
      _AndroidMifareClassicTransport(manager, discovery.handle, discovery));

  /// Async only to match [TransportBackend]'s signature -- no poll is
  /// needed, the identity fields are already in [discovery].
  @override
  Future<IsoDepTransport> isoDep() => Future.value(
      _AndroidIsoDepTransport(manager, discovery.handle, discovery));

  /// Null if the discovery carries no ATQB (i.e. this tag never answered as
  /// ISO14443-B).
  @override
  Future<NfcBTransport?> nfcB() {
    if (discovery.atqb == null) return Future.value(null);
    return Future.value(
        _AndroidNfcBTransport(manager, discovery.handle, discovery));
  }
}

/// Sends [data] over [tech] to [handle] and maps a Kotlin-side `TAG_LOST`
/// platform exception onto the Dart [TagLostException]. Every raw-frame
/// transport member funnels through this so tag-loss is reported uniformly.
Future<Uint8List> _transceive(
    AndroidNfcManager manager, int handle, String tech, Uint8List data) async {
  try {
    return await manager.transceive(handle, tech, data);
  } on PlatformException catch (e) {
    if (e.code == 'TAG_LOST') {
      throw TagLostException(e.message ?? 'tag lost');
    }
    rethrow;
  }
}

class _AndroidType2Transport implements Type2Transport {
  final AndroidNfcManager manager;
  final int handle;
  final NfcTagDiscovery discovery;

  _AndroidType2Transport(this.manager, this.handle, this.discovery);

  @override
  Future<Uint8List> readUid() => Future.value(discovery.uid);

  @override
  Future<Uint8List> readCapabilityContainer() async {
    final data = await _transceive(
        manager, handle, 'NfcA', Uint8List.fromList([0x30, 0x03]));
    return Uint8List.sublistView(data, 0, 4);
  }

  @override
  Future<Uint8List> readPages(int startPage) => _transceive(
      manager, handle, 'NfcA', Uint8List.fromList([0x30, startPage]));

  /// Never throws: an unsupported/failed GET_VERSION (older Ultralight,
  /// tag lost mid-read, anything else) collapses to null, matching
  /// [Type2Transport.getVersion]'s documented contract.
  @override
  Future<Uint8List?> getVersion() async {
    try {
      final data =
          await manager.transceive(handle, 'NfcA', Uint8List.fromList([0x60]));
      if (data.length != 8) return null;
      return data;
    } catch (_) {
      return null;
    }
  }
}

class _AndroidMifareClassicTransport implements MifareClassicTransport {
  final AndroidNfcManager manager;
  final int handle;
  final NfcTagDiscovery discovery;

  _AndroidMifareClassicTransport(this.manager, this.handle, this.discovery);

  @override
  Uint8List get uid => discovery.uid;

  @override
  Uint8List get atqa => discovery.atqa!;

  @override
  int get sak => discovery.sak!;

  /// Android's `MifareClassic.authenticateSectorWithKeyA/B` returns `false`
  /// (not a thrown error) on a rejected key; the Kotlin side surfaces that
  /// as a `PlatformException` (not `TAG_LOST`), which we map to
  /// [MifareAuthException]. A genuinely lost tag surfaces its own
  /// `PlatformException(code: 'TAG_LOST')`, mapped to [TagLostException].
  @override
  Future<void> authenticate(
      int sector, MifareKeyType type, Uint8List key) async {
    try {
      await manager.mifareAuthenticate(
          handle, sector, type == MifareKeyType.a, key);
    } on PlatformException catch (e) {
      if (e.code == 'TAG_LOST') {
        throw TagLostException(e.message ?? 'tag lost');
      }
      throw MifareAuthException(
          e.message ?? 'Authentication failed for sector $sector');
    }
  }

  @override
  Future<Uint8List> readBlock(int block) async {
    try {
      return await manager.mifareReadBlock(handle, block);
    } on PlatformException catch (e) {
      if (e.code == 'TAG_LOST') {
        throw TagLostException(e.message ?? 'tag lost');
      }
      rethrow;
    }
  }
}

class _AndroidNfcFTransport implements NfcFTransport {
  final AndroidNfcManager manager;
  final int handle;
  final NfcTagDiscovery discovery;

  _AndroidNfcFTransport(this.manager, this.handle, this.discovery);

  @override
  Future<Uint8List> get idm => Future.value(discovery.idm!);

  @override
  Future<Uint8List> get pmm => Future.value(discovery.pmm!);

  /// See [NfcFTransport.transceive] for the asymmetric framing contract.
  /// Android's `NfcF.transceive()` requires the caller to prepend a leading
  /// length byte (`felicaFrame.length + 1`) -- there is NO PN532 D4/D5
  /// wrapping here, that dialect is CCID-only.
  @override
  Future<Uint8List> transceive(Uint8List felicaFrame) async {
    final framed = Uint8List.fromList([felicaFrame.length + 1, ...felicaFrame]);
    return _transceive(manager, handle, 'NfcF', framed);
  }
}

class _AndroidIsoDepTransport implements IsoDepTransport {
  final AndroidNfcManager manager;
  final int handle;
  final NfcTagDiscovery discovery;

  _AndroidIsoDepTransport(this.manager, this.handle, this.discovery);

  @override
  Future<Uint8List> get uid => Future.value(discovery.uid);

  @override
  Uint8List? get historicalBytes => discovery.historicalBytes;

  /// Returns the raw response INCLUDING any status word -- DESFire native
  /// mode has none, so nothing is stripped here.
  @override
  Future<Uint8List> transceive(Uint8List apdu) =>
      _transceive(manager, handle, 'IsoDep', apdu);
}

class _AndroidNfcBTransport implements NfcBTransport {
  final AndroidNfcManager manager;
  final int handle;
  final NfcTagDiscovery discovery;

  _AndroidNfcBTransport(this.manager, this.handle, this.discovery);

  @override
  Uint8List get pupi => Uint8List.sublistView(discovery.atqb!, 1, 5);

  @override
  Uint8List get atqb => discovery.atqb!;

  @override
  Future<Uint8List> transceive(Uint8List apdu) =>
      _transceive(manager, handle, 'NfcB', apdu);
}
