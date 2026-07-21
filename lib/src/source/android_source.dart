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
///
/// Two behaviors carried forward from Plan 3 Task 4 and ratified here in
/// Task 7, now that `NfcHub.connectionState()` exists:
///
///  - A [startReaderMode] failure on listen (NFC off, absent, or a
///    transient platform error) is logged, not surfaced through [tags] --
///    there is no synchronous caller left to report it to by the time it
///    happens, since `tags()` has already returned its stream. Availability
///    is `NfcHub.connectionState()`'s job now: an app checks (or watches)
///    it before/while listening to `tagStream()` rather than relying on a
///    thrown error here.
///  - An unrecognized tech list, or a hinted-but-unidentifiable discovery
///    (`identifyFromBackend` throws), is surfaced as a **stream error**
///    (`UnrecognizedTagException`, or the original error) through [tags]
///    rather than being logged and dropped. The user did tap something;
///    silence here would be indistinguishable from a broken reader. It
///    never tears down the stream -- listening continues for the next
///    discovery, mirroring how the CCID probing path logs and continues
///    rather than throwing away the whole session over one card.
///
/// Android reader mode can re-enumerate the same physical tag on a field
/// flicker and call `onTagDiscovered` again for a single tap; without
/// mitigation this reads as two taps. [AndroidNfcSource] debounces this: a
/// discovery whose UID matches the immediately preceding one, arriving
/// within [rediscoverDebounce] of it, is dropped rather than identified
/// again. A different UID, or the same UID after the window, passes
/// through normally.
class AndroidNfcSource implements TagSource {
  AndroidNfcSource(
    this._manager, {
    this.rediscoverDebounce = const Duration(milliseconds: 1000),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AndroidNfcManager _manager;

  /// Same-UID discoveries closer together than this are treated as a
  /// single field-flicker re-enumeration, not a new tap. See the class doc.
  final Duration rediscoverDebounce;
  final DateTime Function() _now;

  String? _lastUidHex;
  DateTime? _lastDiscoveryAt;

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
    unawaited(_manager.startReaderMode().catchError(
      (Object error, StackTrace stackTrace) {
        // Fire-and-forget by design (see the class doc) -- log for
        // debugging visibility, but never surface this as a stream error:
        // `NfcHub.connectionState()` is the app's way to check built-in
        // NFC availability.
        developer.log(
          'startReaderMode() failed: $error',
          name: 'nfc_hub.AndroidNfcSource',
          error: error,
          stackTrace: stackTrace,
        );
      },
    ));
  }

  Future<void> _stop() async {
    await _discoverySub?.cancel();
    _discoverySub = null;
    await _manager.stopReaderMode();
  }

  Future<void> _onDiscovery(NfcTagDiscovery discovery) async {
    final uidHex =
        discovery.uid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final at = _now();
    final lastAt = _lastDiscoveryAt;
    // Reader mode can re-enumerate the SAME physical tag on a field flicker
    // and call onTagDiscovered again -- to an app that is one tap read
    // twice. A same-UID discovery inside the debounce window is that
    // re-enumeration, not a new tap.
    if (uidHex == _lastUidHex &&
        lastAt != null &&
        at.difference(lastAt) < rediscoverDebounce) {
      _lastDiscoveryAt = at;
      return;
    }
    _lastUidHex = uidHex;
    _lastDiscoveryAt = at;

    final hint = hintFromTechList(discovery.techList);
    if (hint == null) {
      // Surface as an error: the user DID tap something; silence here is
      // indistinguishable from a broken reader.
      _controller?.addError(UnrecognizedTagException(
          'Tag with unsupported tech list: ${discovery.techList}'));
      return;
    }
    try {
      final backend = AndroidTransportBackend(_manager, discovery);
      final driver = await identifyFromBackend(backend, hint: hint);
      _controller?.add(driver);
    } catch (error, stackTrace) {
      // Never let one tag's identification failure tear down the stream --
      // surface it as a stream error and keep listening for the next
      // discovery.
      _controller?.addError(error, stackTrace);
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
