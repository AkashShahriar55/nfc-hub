import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log.dart';
import 'nfc_hub_api.dart';
import 'platform/android_nfc_manager.dart';
import 'platform/platform_interface.dart';
import 'source/android_source.dart';
import 'source/ccid_source.dart';
import 'tag/tag_driver.dart';

/// The device's single entry point for both direct CCID/PC-SC access
/// ([listReaders]/[connect], unchanged since before Plan 3) and the unified
/// tag API added in Plan 3 Task 7 ([tagStream]/[readTag]/[connectionState]/
/// [openNfcSettings]), which merges the phone's built-in NFC antenna with
/// CCID/PC-SC readers behind one API.
///
/// The [AndroidNfcManager]/[AndroidNfcSource]/[CcidSource] backing the
/// unified API are constructed lazily, on first use, and reused after that.
/// The constructor parameters below exist purely so tests can substitute
/// fakes for them; production callers should just use `NfcHub()`.
class NfcHub {
  NfcHub({
    @visibleForTesting AndroidNfcManager? androidNfcManager,
    @visibleForTesting AndroidNfcSource? androidNfcSource,
    @visibleForTesting CcidSource? ccidSource,
  })  : _androidNfcManager = androidNfcManager,
        _androidNfcSource = androidNfcSource,
        _ccidSource = ccidSource;

  AndroidNfcManager? _androidNfcManager;
  AndroidNfcSource? _androidNfcSource;
  CcidSource? _ccidSource;
  final Map<CcidSourceFilter?, Stream<TagDriver>> _tagStreams = {};

  AndroidNfcManager get _manager => _androidNfcManager ??= AndroidNfcManager();

  AndroidNfcSource get _nfcSource =>
      _androidNfcSource ??= AndroidNfcSource(_manager);

  CcidSource get _readerSource =>
      _ccidSource ??= CcidSource(NfcHubPlatform.instance);

  /// Turns nfc_hub's diagnostic logging on or off — both halves, Dart and
  /// native — in one call.
  ///
  /// [enabled] gates the event trace: poll-loop lifecycle, reader attach and
  /// detach, card insert and removal, connect/identify outcomes. Roughly a
  /// line per event. This is what you want when a card isn't being detected
  /// and you need to know how far it got.
  ///
  /// [verbose] additionally dumps every CCID USB frame on the native side —
  /// raw bulk-in/out hex and decoded `RDR_to_PC` headers. This is a firehose:
  /// the poll loop probes twice a second at ~5 lines each, so an idle reader
  /// produces well over a thousand lines a minute. Leave it off unless you
  /// need to see the wire. It has no effect when [enabled] is false.
  ///
  /// Errors are always logged, at any setting.
  ///
  /// Call it once at startup, before anything begins polling:
  ///
  /// ```dart
  /// await NfcHub().setLogging(enabled: true);              // events only
  /// await NfcHub().setLogging(enabled: true, verbose: true); // + USB frames
  /// await NfcHub().setLogging(enabled: false);             // silence
  /// ```
  ///
  /// Safe to call at any time — settings apply to subsequent logging, and a
  /// platform with no native half to configure ignores it.
  Future<void> setLogging({bool enabled = true, bool verbose = false}) async {
    nfcHubLogging = enabled;
    nfcHubVerboseLogging = verbose;
    await NfcHubPlatform.instance.setLogging(
      enabled: enabled,
      verbose: verbose,
    );
  }

  /// List available readers
  ///
  /// Returns a list of reader names
  Future<List<String>> listReaders() {
    return NfcHubPlatform.instance.listReaders();
  }

  /// Connect to a reader by its name [reader]
  ///
  /// Returns a [CcidCard] object
  Future<CcidCard> connect(String reader) {
    return NfcHubPlatform.instance.connect(reader);
  }

  /// A unified stream of identified tags from both the phone's built-in NFC
  /// antenna and every attached CCID/PC-SC reader, merged behind one API --
  /// an app never has to know, or branch on, which source produced a tag.
  ///
  /// Pass [from] to restrict to a single source instead: a
  /// [CcidSourceFilter.builtInNfc] for the phone's own antenna, or a
  /// [CcidSourceFilter.reader] for one named CCID/PC-SC reader. Omit it (or
  /// pass `null`) to receive tags from every source, interleaved as they
  /// arrive.
  ///
  /// Starts whichever underlying source(s) the filter selects on first
  /// listen, and stops them once the last listener of this stream cancels.
  ///
  /// Returns the same stream instance for equal filter values, so multiple
  /// listeners share one pipeline (one set of source subscriptions) instead
  /// of creating parallel pipelines.
  Stream<TagDriver> tagStream({CcidSourceFilter? from}) {
    return _tagStreams[from] ??= mergeTagStreams(
      androidSource: _nfcSource,
      ccidSource: _readerSource,
      filter: from,
    );
  }

  /// Returns the first tag seen on [tagStream] (optionally narrowed by
  /// [from]).
  ///
  /// If [timeout] is given and no tag arrives within it, the returned
  /// future completes with a [TimeoutException] instead -- and, since the
  /// timeout is applied to the stream itself (not raced against `.first`),
  /// the underlying source(s) (Android reader mode / the CCID poll loop)
  /// are stopped just like they are when a tag actually arrives, rather
  /// than being left running forever.
  ///
  /// Because this is backed by `.first`, the returned future also completes
  /// with an error -- it does NOT keep waiting for a later, successful tap
  /// -- if the very first event on the stream is itself an error: an
  /// unreadable/unrecognized tap (e.g. [UnrecognizedTagException] from an
  /// Android discovery whose tech list matches nothing known, or the
  /// underlying identification failure for a tag that connects but can't be
  /// identified). A caller that wants "keep prompting the user until a tag
  /// is actually read" behavior -- tap-until-success, ignoring bad taps in
  /// between -- should use [tagStream] (or `NfcHubReader.startSession`)
  /// directly and handle `onError` itself, rather than [readTag].
  Future<TagDriver> readTag({CcidSourceFilter? from, Duration? timeout}) {
    final stream = tagStream(from: from);
    if (timeout == null) return stream.first;
    return stream
        .timeout(
          timeout,
          onTimeout: (sink) => sink.addError(
            TimeoutException('readTag timed out after $timeout', timeout),
          ),
        )
        .first;
  }

  /// A stream of the combined connection state: whether the phone's
  /// built-in NFC antenna is currently available (and why not, if it
  /// isn't), plus the live presence state of every attached CCID/PC-SC
  /// reader.
  Stream<CcidConnectionState> connectionState() {
    return combineConnectionState(
      manager: _manager,
      ccidSource: _readerSource,
    );
  }

  /// Opens the system NFC settings screen, so the user can turn NFC on.
  Future<void> openNfcSettings() => _manager.openNfcSettings();

  /// A cheap, side-effect-free snapshot of whether any source can read right
  /// now: true when the phone's NFC is enabled, or at least one CCID/PC-SC
  /// reader is attached. Deliberately does NOT start the CCID poll loop (so it
  /// never triggers the USB permission dialog) — it only reads the NFC state
  /// and lists readers. Any error resolving either source is treated as "that
  /// source is unavailable" rather than propagating.
  Future<bool> isAvailable() async {
    var nfcEnabled = false;
    try {
      nfcEnabled = (await _manager.getNfcState()) == NfcState.enabled;
    } catch (_) {
      nfcEnabled = false;
    }
    if (nfcEnabled) return true;
    try {
      return (await listReaders()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}

class CcidCard {
  final String reader;

  /// The card's answer-to-reset, captured at connect time where the
  /// platform supports it (Android only, currently). Null on platforms/
  /// paths that don't surface it — `identifyTag` falls back to capability
  /// probing in that case.
  final Uint8List? atr;

  CcidCard(this.reader, {this.atr});

  /// Clock used to stamp [lastActivity]. Overridable (by [CcidSource], right
  /// after a successful connect) so tests can drive both the card's activity
  /// timestamps and the source's poll-loop comparisons off one shared fake
  /// clock instead of the card using real time while the source uses an
  /// injected one. Not part of the app-facing API: apps must never set this.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// Completion time of the most recent [transceive] (success OR failure).
  /// Null until the first transceive completes. CcidSource uses this to skip
  /// its liveness probe while the app is actively talking to the card.
  DateTime? lastActivity;

  // Serializes transceives per card: an APDU never starts until the
  // previous one completes. Probing and multi-step driver flows share one
  // card; without this, a poll-loop probe can land between two frames of a
  // chained command (DESFire GetVersion, MIFARE load-key/auth) and abort it.
  Future<void> _chain = Future<void>.value();

  /// Send APDU command [capdu]
  ///
  /// Returns the response APDU. Serialized: if another [transceive] on this
  /// same card is still in flight, this one waits for it to complete (success
  /// or failure) before its own APDU is sent.
  Future<String?> transceive(String capdu) {
    final completer = Completer<String?>();
    _chain = _chain.then((_) async {
      try {
        completer
            .complete(await NfcHubPlatform.instance.transceive(reader, capdu));
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        lastActivity = now();
      }
    });
    return completer.future;
  }

  /// Disconnect from the card
  Future<void> disconnect() {
    return NfcHubPlatform.instance.disconnect(reader);
  }
}
