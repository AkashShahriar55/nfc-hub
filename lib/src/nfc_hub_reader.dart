import 'dart:async';

import 'package:flutter/foundation.dart';

import 'nfc_hub_api.dart';
import 'nfc_hub_base.dart';
import 'tag/tag_driver.dart';

/// Friendly alias for a discovered, already-identified tag. Identical to the
/// [TagDriver] the stream API emits — cast to a family subtype
/// ([MifareClassicTag], [Type2Tag], [FelicaTag], [IsoDepTag], [TypeBTag]) to
/// perform that family's reads.
typedef NfcTag = TagDriver;

/// A simple, `nfc_manager`-style singleton facade over [NfcHub].
///
/// The common case is three calls: grab [instance], [startSession] with an
/// `onDiscovered` callback, and [stopSession] when done. Every capability here
/// is a thin wrapper over the [NfcHub] stream API, which stays public for
/// callers that want streams, timeouts, or per-source filtering directly.
class NfcHubReader {
  /// The process-wide singleton entry point. Synchronous — no `await`.
  static final NfcHubReader instance = NfcHubReader._(NfcHub());

  NfcHubReader._(this._hub);

  /// Test seam: build a reader over an injected [NfcHub] (usually one wired to
  /// fakes). Production code uses [instance].
  @visibleForTesting
  factory NfcHubReader.forTesting(NfcHub hub) = NfcHubReader._;

  final NfcHub _hub;

  StreamSubscription<NfcTag>? _session;

  // Serializes onDiscovered across the reader's entire lifetime: each call is
  // chained onto the previous one's Future so the (N+1)th never begins until
  // the Nth completes. This is a rolling future that always resolves and is
  // never reset — so serialization holds even across a startSession replace: a
  // new session's first read waits for any still-in-flight previous read,
  // preserving the single-threaded-reader guarantee.
  Future<void> _chain = Future<void>.value();

  /// A cheap snapshot of whether any source can read right now. See
  /// [NfcHub.isAvailable].
  Future<bool> isAvailable() => _hub.isAvailable();

  /// Live, detailed connection state for building a status UI. Passthrough to
  /// [NfcHub.connectionState].
  Stream<NfcConnectionState> connectionState() => _hub.connectionState();

  /// Opens the system NFC settings screen so the user can enable NFC.
  Future<void> openNfcSettings() => _hub.openNfcSettings();

  /// Starts auto-detecting tags from all sources (or the one named by [from]).
  ///
  /// [onDiscovered] is called once per tag as it arrives; if it returns a
  /// Future it is awaited before the next tag is delivered, so reads on one tag
  /// never overlap the next (important for the single-threaded CCID reader). A
  /// throwing/failing [onDiscovered] is isolated — it does not tear down the
  /// session, and whatever it threw (e.g. a `TagLostException` when the tag
  /// leaves the field mid-read) is reported to this session's [onError].
  /// [onError], if given, also receives stream errors — this
  /// includes per-tap failures (e.g. an unreadable/unrecognized tag, or a
  /// tag that connects but fails identification), not just connection-level
  /// errors: the session survives these and keeps delivering later taps. If
  /// [onError] is omitted, all such errors are silently swallowed (the
  /// session stays alive), so always supply [onError] and use it to show a
  /// lightweight "couldn't read tag, try again" UI rather than leaving
  /// failed taps unexplained. Calling
  /// startSession while a session is active first stops the previous one; the
  /// serialization chain is not reset, so the new session's first read still
  /// waits for any still-in-flight previous read (no overlap across a replace).
  void startSession({
    required FutureOr<void> Function(NfcTag tag) onDiscovered,
    void Function(Object error)? onError,
    NfcSource? from,
  }) {
    // Replace any active session. Cancel is fire-and-forget: the synchronous
    // prefix here (reading and nulling _session) completes before anything
    // else touches it, so no new subscription races the old one.
    final previous = _session;
    _session = null;
    if (previous != null) unawaited(previous.cancel());

    _session = _hub.tagStream(from: from).listen(
      (tag) {
        _chain = _chain.then((_) async {
          try {
            await onDiscovered(tag);
          } catch (error) {
            // A throwing callback must not break the session or the chain --
            // but the app must still hear about it (e.g. TagLostException
            // mid-read), so report it to THIS session's onError. `onError`
            // is the startSession parameter captured by this closure: if the
            // session has since been replaced, an in-flight read still
            // reports to the session it belonged to, which is correct.
            // Guard the report itself: an onError that throws must not fail
            // this chain entry, or every later onDiscovered would be
            // silently skipped for the session's lifetime.
            try {
              onError?.call(error);
            } catch (_) {}
          }
        });
      },
      onError: (Object error) => onError?.call(error),
    );
  }

  /// Stops the active session and releases its subscription: no further tags
  /// are delivered. No-op if there is no active session; safe to call
  /// repeatedly. Note this does NOT await an [onDiscovered] callback that is
  /// already in flight — that call runs to completion in the background, so
  /// "stopped" means "no more deliveries", not "all reader activity finished".
  Future<void> stopSession() async {
    final sub = _session;
    _session = null;
    await sub?.cancel();
  }
}
