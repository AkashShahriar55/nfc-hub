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

/// Friendly alias over the connection-state type the stream API emits.
typedef NfcConnectionState = CcidConnectionState;

/// Which source a [NfcHubReader.startSession] listens to. Omit (pass null) for
/// all sources merged — the seamless default. A thin wrapper over
/// [CcidSourceFilter].
@immutable
class NfcSource {
  /// Only the phone's built-in NFC antenna.
  const NfcSource.builtIn()
      : _reader = null,
        _isBuiltIn = true;

  /// Only the named CCID/PC-SC reader, exactly as reported by
  /// [NfcHub.listReaders].
  const NfcSource.reader(String name)
      : _reader = name,
        _isBuiltIn = false;

  final String? _reader;
  final bool _isBuiltIn;

  /// Maps to the underlying stream-API filter.
  @visibleForTesting
  CcidSourceFilter toFilter() => _isBuiltIn
      ? const CcidSourceFilter.builtInNfc()
      : CcidSourceFilter.reader(_reader!);
}

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

  // Serializes onDiscovered: each call is chained onto the previous one's
  // Future so the (N+1)th never begins until the Nth completes. Reset on every
  // startSession so a new session starts with a clean chain.
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
  /// session. [onError], if given, receives stream errors. Calling
  /// startSession while a session is active first stops the previous one.
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
    _chain = Future<void>.value();

    _session = _hub.tagStream(from: from?.toFilter()).listen(
      (tag) {
        _chain = _chain.then((_) async {
          try {
            await onDiscovered(tag);
          } catch (_) {
            // A throwing callback must not break the session or the chain.
          }
        });
      },
      onError: (Object error) => onError?.call(error),
    );
  }

  /// Stops the active session and releases its subscription. No-op if there is
  /// no active session. Safe to call repeatedly.
  Future<void> stopSession() async {
    final sub = _session;
    _session = null;
    await sub?.cancel();
  }
}
