import 'dart:async';
import 'dart:developer' as developer;

import '../platform/android_nfc_manager.dart';
import '../tag/detection.dart';
import '../tag/tag_driver.dart';
import '../transport/android_backend.dart';
import '../transport/backend.dart';
import 'tag_source.dart';

/// Maps Android's fully-qualified `android.nfc.tech.*` class names -- as
/// reported by `Tag.getTechList()` and carried on
/// [NfcTagDiscovery.techList] -- to a [TagTechHint], so [AndroidNfcSource]
/// can skip capability probing entirely and build the right driver
/// directly.
///
/// This is a DIFFERENT string space from the bare tech selector
/// (`NfcA`/`IsoDep`/...) that `AndroidTransportBackend` passes to
/// `manager.transceive`; this function only ever matches fully-qualified
/// class names and never produces or consumes the bare selector.
///
/// Checked in this exact order because a tag's tech list is a superset, not
/// a single value -- a MIFARE Classic tag also lists `NfcA` (it must map to
/// [TagTechHint.mifareClassic], not [TagTechHint.type2]); an IsoDep tag also
/// lists `NfcB` in some stacks (it must map to [TagTechHint.isoDep], not
/// [TagTechHint.typeB]).
///
/// Returns null when none of the known techs are present -- an unrecognized
/// or unsupported tag. The caller must skip such a discovery, not crash.
TagTechHint? hintFromTechList(List<String> techList) {
  bool has(String cls) => techList.contains(cls);

  if (has('android.nfc.tech.MifareClassic')) return TagTechHint.mifareClassic;
  if (has('android.nfc.tech.NfcF')) return TagTechHint.felica;
  if (has('android.nfc.tech.IsoDep')) return TagTechHint.isoDep;
  if (has('android.nfc.tech.NfcB')) return TagTechHint.typeB;
  if (has('android.nfc.tech.NfcA')) return TagTechHint.type2;
  return null;
}

/// Turns the phone's built-in-antenna discovery stream
/// ([AndroidNfcManager.discoveries]) into a stream of identified
/// [TagDriver]s.
///
/// For each discovery: derives a [TagTechHint] from its tech list (via
/// [hintFromTechList]), builds an [AndroidTransportBackend] addressed at
/// that discovery, and calls [identifyFromBackend] with the hint -- no
/// probing needed, since the tech list is a definitive signal. A discovery
/// whose tech list matches no known hint is logged and skipped; it never
/// tears down the stream (mirroring how the CCID probing path logs and
/// continues rather than throwing away the whole session over one card).
///
/// Starts Android reader mode ([AndroidNfcManager.startReaderMode]) on the
/// first listen and stops it ([AndroidNfcManager.stopReaderMode]) once the
/// last listener cancels, so the antenna is only kept hot while something
/// is actually consuming [tags].
class AndroidNfcSource implements TagSource {
  AndroidNfcSource(this._manager);

  final AndroidNfcManager _manager;
  StreamController<TagDriver>? _controller;
  StreamSubscription<NfcTagDiscovery>? _discoverySub;

  @override
  Stream<TagDriver> tags() {
    return (_controller ??= StreamController<TagDriver>.broadcast(
      onListen: _start,
      onCancel: _stop,
    ))
        .stream;
  }

  void _start() {
    _discoverySub = _manager.discoveries.listen(
      _onDiscovery,
      onError: (Object error, StackTrace stackTrace) {
        _controller?.addError(error, stackTrace);
      },
    );
    unawaited(_manager.startReaderMode());
  }

  Future<void> _stop() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    await _manager.stopReaderMode();
  }

  Future<void> _onDiscovery(NfcTagDiscovery discovery) async {
    final hint = hintFromTechList(discovery.techList);
    if (hint == null) {
      developer.log(
        'Skipping tag with unrecognized tech list: ${discovery.techList}',
        name: 'nfc_hub.AndroidNfcSource',
      );
      return;
    }
    try {
      final backend = AndroidTransportBackend(_manager, discovery);
      final driver = await identifyFromBackend(backend, hint: hint);
      _controller?.add(driver);
    } catch (error, stackTrace) {
      // Never let one tag's identification failure tear down the stream --
      // log it and keep listening for the next discovery.
      developer.log(
        'Failed to identify tag (hint: $hint): $error',
        name: 'nfc_hub.AndroidNfcSource',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_discoverySub != null) {
      await _stop();
    }
    await _controller?.close();
  }
}
