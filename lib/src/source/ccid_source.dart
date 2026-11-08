import 'dart:async';

import 'package:flutter/services.dart';

import '../log.dart';
import '../nfc_hub_base.dart';
import '../platform/platform_interface.dart';
import '../tag/detection.dart';
import '../tag/tag_driver.dart';
import 'tag_source.dart';

/// A CCID/PC-SC reader's card-presence state, as tracked by [CcidSource]'s
/// poll loop and surfaced to Task 7's unified connection-state stream.
class ExternalReaderState {
  /// The reader's name, exactly as reported by [NfcHubPlatform.listReaders].
  final String name;

  /// Whether a card is currently seated in this reader.
  final bool cardPresent;

  const ExternalReaderState(this.name, this.cardPresent);

  @override
  bool operator ==(Object other) =>
      other is ExternalReaderState &&
      other.name == name &&
      other.cardPresent == cardPresent;

  @override
  int get hashCode => Object.hash(name, cardPresent);

  @override
  String toString() => 'ExternalReaderState($name, cardPresent: $cardPresent)';
}

/// Whether a tracked reader currently has no card seated ([empty]), or has
/// a card connected and already identified ([occupied]).
enum _ReaderStatus { empty, occupied }

/// A [TagDriver] paired with the name of the CCID reader that produced it.
///
/// [CcidSource] itself has no notion of "filtering" -- that's Task 7's
/// concern (`NfcHub.tagStream(from: NfcSource.reader(...))`). This
/// type exists purely so a consumer of [CcidSource.taggedTags] can tell
/// which reader each driver came from without [CcidSource] needing to know
/// about filters at all.
class ReaderTaggedDriver {
  const ReaderTaggedDriver(this.reader, this.driver);

  /// The reader's name, exactly as reported by [NfcHubPlatform.listReaders].
  final String reader;

  final TagDriver driver;
}

/// A [TagDriver] identified for a currently-**occupied** reader, held so it
/// can be delivered to whichever [CcidSource.tags]/[CcidSource.taggedTags]
/// subscriber sees it first -- see the class doc's delivery contract.
/// [delivered] flips to true the moment the driver reaches a subscriber
/// whose (optional) reader filter matches it (live forwarding at identify
/// time, or replay to a first later matching subscriber) and gates every
/// replay after that: a presentation is never replayed once ANY matching
/// consumer has actually received it. A subscriber filtered to a DIFFERENT
/// reader never marks it -- discarding an event must not consume it.
class _HeldDriver {
  _HeldDriver(this.driver);

  final TagDriver driver;
  bool delivered = false;
}

/// PC/SC Part 3 "Get Data" (Get UID) pseudo-APDU. Reused here purely as a
/// liveness probe for an already-[_ReaderStatus.occupied] reader -- any
/// contactless storage card answers it, so a throw/failure is a reliable
/// signal that the card was pulled. (This is the same pseudo-APDU
/// [CcidTransportBackend]'s `Type2Transport.readUid` and `NfcFTransport.idm`
/// use for an actual UID read; here only success/failure matters.)
///
/// This assumes the reader answers `FFCA000000` for a present card of any
/// family -- validated by hand on the ACR122U for MIFARE, Type B, and
/// FeliCa. A card family that *throws* rather than returns null/an error
/// SW on this pseudo-APDU (instead of the failure modes seen so far) could
/// false-trigger a removal on an otherwise-still-present card. Flagged for
/// further hardware validation across reader/card combinations, not a code
/// fix -- do not change this probe APDU as part of addressing that risk.
const _probeApdu = 'FFCA000000';

/// Turns the CCID/PC-SC readers [NfcHubPlatform] can see into a stream of
/// identified [TagDriver]s -- the same shape [AndroidNfcSource] gives the
/// phone's built-in antenna -- so Task 7 can merge both into one unified
/// stream.
///
/// Unlike the phone's antenna, CCID readers expose no discovery/interrupt
/// callback through this plugin's platform surface -- only
/// [NfcHubPlatform.listReaders]/[NfcHubPlatform.connect]/
/// [NfcHubPlatform.transceive]. So [CcidSource] drives a [Timer.periodic]
/// that repeatedly polls every attached reader, tracking a per-reader state
/// machine:
///
///  - **empty**: attempts [NfcHubPlatform.connect]. Success means a card
///    was just seated -- the reader moves to **occupied**, the card is
///    identified via [identifyTag], and the resulting driver is emitted on
///    [tags]. A throw means still no card -- stays **empty**, nothing
///    emitted.
///  - **occupied**: sends the harmless [_probeApdu] through the occupied
///    reader's [ReaderCard] (so it's serialized with, and skipped entirely
///    during, any in-flight driver transceive -- see [_probeStillPresent])
///    as a liveness check. Success means the same card is still seated --
///    nothing is re-emitted (a card that stays put emits exactly once). A
///    throw means the card was removed -- the reader moves back to
///    **empty**, [NfcHubPlatform.disconnect] releases the connection the
///    emitted [TagDriver] was holding, and the next tick's empty-handling
///    can pick up a re-insertion.
///
/// [tags], [taggedTags], and [readerStates] share one listener count, and
/// the connect/identify/emit path runs whenever ANY of them is listening.
/// So an app can listen to [readerStates] (via `NfcHub.connectionState()`)
/// BEFORE [tags] (via `NfcHub.tagStream()`) -- e.g. a status bar wired up
/// before the user hits "read" -- and a card seated in that window would be
/// identified while nothing is listening to [tags] yet. To avoid losing
/// that card, [CcidSource] holds the built [TagDriver] for every
/// **occupied** reader in [_occupiedDrivers] as a [_HeldDriver].
///
/// **Each card presentation is replayed at most once** -- and only to a
/// consumer whose filter actually matches it. Live delivery at identify
/// time can fan out to SEVERAL simultaneous [tags]/[taggedTags] listeners
/// (that is documented behavior); the moment a matching listener receives
/// it live, the presentation is marked [_HeldDriver.delivered] and gated
/// out of every later replay. A presentation NOT consumed by any matching
/// listener (nobody listening yet, or only listeners filtered to OTHER
/// readers) sits held and undelivered until [tags]/[taggedTags] -- built
/// with [Stream.multi] -- attach a new subscription: each NEW
/// subscription's callback synchronously scans the held drivers and replays
/// only the still-undelivered ones its own filter matches, marking each
/// delivered as it does. A widget rebuild or session restart that cancels
/// and re-listens therefore does NOT see a card its predecessor
/// subscription already received -- and a second listener joining after the
/// first already got it sees nothing either. Crucially, a subscription
/// filtered to reader A never consumes reader B's card: B's presentation
/// stays held for the first later subscriber that DOES match it.
/// `Stream.multi` runs its callback once per subscription (unlike
/// `.broadcast()`, whose `add` always reaches every current listener at
/// once), so this replay-and-mark check only ever runs for the
/// newly-attached subscriber.
///
/// A reader that disappears from [NfcHubPlatform.listReaders] entirely
/// (unplugged) is dropped from tracking outright, disconnecting first if it
/// was occupied. [dispose] does the same for every still-occupied reader.
/// A still-occupied reader is NEVER disconnected while the card remains
/// present -- the emitted [TagDriver] holds that same connection open so
/// the app can drive reads (`readNdef`, `readSector`, etc.) against it.
///
/// The loop only runs while [tags], [taggedTags], or [readerStates] has a
/// listener --
/// mirroring [AndroidNfcSource]'s onListen/onCancel gating -- so nothing
/// stays "hot" (USB traffic, and on real hardware, the user-facing
/// permission prompt triggered by [NfcHubPlatform.connect] -- see the
/// warning on [CcidSource] itself) with nobody consuming it.
///
/// On Android, [NfcHubPlatform.connect] surfaces the OS's USB accessory
/// permission dialog the first time a given reader is seen, since it opens
/// the USB device. Because the empty-reader branch above calls `connect`
/// once per poll tick for every reader with no card seated, a reader that
/// is attached but *never* has a card in it, or a user who dismisses the
/// dialog, causes that prompt to reappear on a future tick. There is no way
/// to probe "is a card present" without this connect side effect through
/// the current plugin API -- that trade-off is inherent to this design and
/// cannot be exercised by these pure-Dart tests, only on real hardware.
class CcidSource implements TagSource {
  CcidSource(
    this._platform, {
    this.pollInterval = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final NfcHubPlatform _platform;
  final Duration pollInterval;

  /// Clock used to decide whether a card has had recent activity (see
  /// [_probeStillPresent]). Overridable purely for testability -- shared
  /// with each occupied reader's [ReaderCard] (wired in [_tryConnect]) so both
  /// sides compare against the same notion of "now".
  final DateTime Function() _now;

  StreamController<ReaderTaggedDriver>? _taggedTagsController;
  StreamController<List<ExternalReaderState>>? _statesController;
  Timer? _timer;
  int _listenerCount = 0;
  bool _ticking = false;

  /// Diagnostic counters: [_tickCount] drives the poll-loop heartbeat log,
  /// [_skippedTicks] counts consecutive ticks dropped because the previous
  /// one was still in flight (a wedged platform call).
  int _tickCount = 0;
  int _skippedTicks = 0;

  /// Last connect-failure message logged per reader. An empty reader fails
  /// connect() on EVERY tick, so the message is logged only when it changes
  /// -- one line per distinct failure mode instead of two per second.
  final Map<String, String> _lastConnectFailure = {};

  final Map<String, _ReaderStatus> _status = {};

  /// The [_HeldDriver] for every currently-**occupied** reader, keyed by
  /// reader name. Populated the instant [_tryConnect] identifies a newly
  /// seated card, and cleared the instant that reader goes back to
  /// **empty** (probe failure, vanish, or [dispose]). This is the source of
  /// truth [tags]/[taggedTags] consult to decide whether a subscriber that
  /// attaches after the card was already identified still needs it -- see
  /// the class doc for the exactly-once contract.
  final Map<String, _HeldDriver> _occupiedDrivers = {};

  /// The [ReaderCard] backing every currently-**occupied** reader, keyed by
  /// reader name. Populated alongside [_occupiedDrivers] in [_tryConnect] and
  /// cleared everywhere [_occupiedDrivers] is cleared. [_probeStillPresent]
  /// routes its liveness probe through this card (serialized with any
  /// in-flight driver transceive) rather than the raw platform, and consults
  /// its [ReaderCard.lastActivity] to skip the probe while the app is actively
  /// reading.
  final Map<String, ReaderCard> _occupiedCards = {};

  /// The occupied card's Get-UID probe response (hex), captured at connect
  /// time and keyed by reader name. Lets [_probeStillPresent] tell "the same
  /// card is still here" from "a DIFFERENT card was swapped in" (a changed
  /// UID). Empty string if the card doesn't answer the probe (e.g. Type B) --
  /// then the probe falls back to presence-only. Cleared alongside
  /// [_occupiedDrivers].
  final Map<String, String> _occupiedUid = {};

  /// Readers whose USB permission the user denied. connect() is NOT retried
  /// for these (each retry re-shows the OS dialog); the reader must detach
  /// and re-attach (it then leaves _status and this set) to be retried.
  final Set<String> _permissionDenied = {};

  /// The single shared live broadcast pipeline behind [tags] and
  /// [taggedTags]. Created lazily; its onListen/onCancel keep the poll
  /// loop's listener count single-sourced (a broadcast controller fires
  /// onListen on the 0->1 listener transition and onCancel on the last
  /// cancel, so it contributes at most one "someone is consuming tags" unit
  /// to [_listenerCount] alongside [_statesController]).
  StreamController<ReaderTaggedDriver> get _liveTaggedController =>
      _taggedTagsController ??= StreamController<ReaderTaggedDriver>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      );

  /// Thin wrapper over [taggedTags] that strips the reader name -- ALL
  /// hold/replay/delivered-marking logic lives in [taggedTags], so the two
  /// entry points can never disagree about whether a presentation was
  /// consumed, and the poll-loop listener count stays single-sourced.
  @override
  Stream<TagDriver> tags() => taggedTags().map((tagged) => tagged.driver);

  /// The same tags as [tags], but paired with the reader that produced each
  /// one -- see [ReaderTaggedDriver]. Used by Task 7's unified stream to
  /// implement `NfcSource.reader(name)`, by passing that name as
  /// [reader].
  ///
  /// With a non-null [reader], only that reader's drivers are delivered --
  /// and, crucially, only that reader's presentations are ever CONSUMED:
  /// a filtered subscription neither replays nor marks-delivered a held
  /// driver from any other reader, so another reader's card stays held for
  /// the first later subscriber whose filter matches it (see the class doc).
  ///
  /// Built as a [Stream.multi] (isBroadcast: true): the callback runs once
  /// per subscription, each with its OWN controller -- unlike a plain
  /// `.broadcast()` stream where a single `add` reaches every listener at
  /// once. That per-subscription isolation is what lets a NEW listener's
  /// replay-and-mark scan run exactly once, for exactly that subscriber,
  /// without a concurrent listener's attach racing it. The live path then
  /// forwards from the one shared broadcast controller, marking the held
  /// driver delivered only when this subscription actually forwards it to
  /// its consumer.
  Stream<ReaderTaggedDriver> taggedTags({String? reader}) {
    return Stream<ReaderTaggedDriver>.multi((controller) {
      for (final entry in _occupiedDrivers.entries) {
        if (reader != null && entry.key != reader) continue;
        final held = entry.value;
        if (!held.delivered) {
          held.delivered = true;
          controller.add(ReaderTaggedDriver(entry.key, held.driver));
        }
      }
      final live = _liveTaggedController.stream.listen(
        (tagged) {
          if (reader != null && tagged.reader != reader) return;
          // This event is reaching a real consumer -- mark the presentation
          // spent so no later subscriber's replay scan hands it out again.
          // (Guard on identity: the held driver may already belong to a
          // NEWER presentation on the same reader.)
          final held = _occupiedDrivers[tagged.reader];
          if (held != null && identical(held.driver, tagged.driver)) {
            held.delivered = true;
          }
          controller.add(tagged);
        },
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = live.cancel;
    }, isBroadcast: true);
  }

  /// The current per-reader `{name, cardPresent}` list, re-emitted whenever
  /// it changes: a reader attaches/detaches, or a card is inserted/removed.
  /// Consumed by Task 7's unified connection-state stream.
  Stream<List<ExternalReaderState>> readerStates() {
    return (_statesController ??=
            StreamController<List<ExternalReaderState>>.broadcast(
      onListen: _onListen,
      onCancel: _onCancel,
    ))
        .stream;
  }

  void _onListen() {
    _listenerCount++;
    if (_listenerCount == 1) {
      nfcLog('poll loop STARTED (interval $pollInterval)');
      _timer = Timer.periodic(pollInterval, (_) => unawaited(_tick()));
    } else {
      nfcLog('poll loop: listener added (now $_listenerCount)');
    }
  }

  void _onCancel() {
    _listenerCount--;
    if (_listenerCount <= 0) {
      _listenerCount = 0;
      nfcLog('poll loop STOPPED (last listener cancelled)');
      _timer?.cancel();
      _timer = null;
    } else {
      nfcLog('poll loop: listener removed (now $_listenerCount)');
    }
  }

  Future<void> _tick() async {
    // A previous tick may still be in flight (e.g. a slow connect()) --
    // never run two ticks concurrently against the same reader state.
    if (_ticking) {
      // Sustained repeats here mean a platform call never completed: the loop
      // is wedged and NO card will ever be detected until it unblocks.
      _skippedTicks++;
      if (_skippedTicks == 1 || _skippedTicks % 20 == 0) {
        nfcLog('tick SKIPPED -- previous tick still in flight '
            '(x$_skippedTicks, ~${_skippedTicks * pollInterval.inMilliseconds}ms)');
      }
      return;
    }
    _skippedTicks = 0;
    _ticking = true;
    _tickCount++;
    // Heartbeat: proof the loop is alive, plus the current per-reader state,
    // without logging all of it 2x/second.
    if (_tickCount % 20 == 1) {
      nfcLog('tick #$_tickCount: status=$_status '
          'occupied=${_occupiedDrivers.keys.toList()} '
          'permissionDenied=${_permissionDenied.toList()}');
    }
    try {
      await _pollOnce();
    } catch (error, stackTrace) {
      // Never let one bad poll tear down the timer -- log and try again
      // next tick, mirroring AndroidNfcSource's per-discovery isolation.
      nfcLog(
        'CcidSource poll tick failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _ticking = false;
    }
  }

  Future<void> _pollOnce() async {
    List<String> readers;
    try {
      readers = await _platform.listReaders();
    } catch (error, stackTrace) {
      nfcLog(
        'listReaders() failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }

    final readerSet = readers.toSet();
    var changed = false;

    // Drop tracking for readers that vanished (unplugged) since last tick.
    final vanished = _status.keys.where((r) => !readerSet.contains(r)).toList();
    for (final reader in vanished) {
      final wasOccupied = _status[reader] == _ReaderStatus.occupied;
      nfcLog('reader "$reader": VANISHED from listReaders (was '
          '${wasOccupied ? 'occupied' : 'empty'}) -- dropping tracking');
      _status.remove(reader);
      _permissionDenied.remove(reader);
      _lastConnectFailure.remove(reader);
      changed = true;
      // The reader itself is gone, so any connection held for its card is
      // no longer reachable through it -- release the handle rather than
      // leaking it (Android: an unclosed USB device handle; PC/SC: a Card
      // whose context.release() would otherwise never fire).
      if (wasOccupied) {
        // Clear the held driver + UID baseline SYNCHRONOUSLY, before the
        // disconnect await -- otherwise a listener attaching to
        // tags()/taggedTags() during that await window replays a driver for a
        // card that is already gone, over a connection that is mid-teardown.
        _occupiedDrivers.remove(reader);
        _occupiedCards.remove(reader);
        _occupiedUid.remove(reader);
        await _disconnectQuietly(reader);
      }
    }

    // Start tracking newly-seen readers as empty.
    for (final reader in readers) {
      if (!_status.containsKey(reader)) {
        nfcLog('reader "$reader": now tracked (empty)');
        _status[reader] = _ReaderStatus.empty;
        changed = true;
      }
    }

    for (final reader in readers) {
      final status = _status[reader];
      if (status == _ReaderStatus.empty) {
        if (_permissionDenied.contains(reader)) continue;
        if (await _tryConnect(reader)) changed = true;
      } else if (status == _ReaderStatus.occupied) {
        if (!await _probeStillPresent(reader)) changed = true;
      }
    }

    if (changed) _emitStates();
  }

  /// Attempts to connect an **empty** reader. Returns true (and emits a
  /// [TagDriver]) if a card was just seated; false if the reader is still
  /// empty.
  Future<bool> _tryConnect(String reader) async {
    final ReaderCard card;
    try {
      card = await _platform.connect(reader);
    } on PlatformException catch (e) {
      if (e.code == 'CCID_PERMISSION_DENIED') {
        _permissionDenied.add(reader);
        nfcLog('reader "$reader": USB PERMISSION DENIED -- connect() will not '
            'be retried until the reader is re-attached');
        return false;
      }
      // "No card seated" is indistinguishable from a real failure here without
      // the code+message, and this fires every tick -- so log on change only.
      _logConnectFailure(reader, '${e.code}: ${e.message}');
      return false;
    } catch (error) {
      _logConnectFailure(reader, '$error');
      return false; // No card seated yet -- stays empty, nothing to report.
    }
    _lastConnectFailure.remove(reader);
    nfcLog('reader "$reader": CONNECTED, atr=${card.atr}');

    _status[reader] = _ReaderStatus.occupied;
    // Share one clock between this card and the source, so lastActivity
    // (stamped on the card) and _now() (read by _probeStillPresent) agree on
    // "now" -- matters under a test's injected fake clock. CcidSource is the
    // one sanctioned production writer of ReaderCard.now (the @visibleForTesting
    // annotation exists to keep APPS from setting it), hence the ignore.
    // ignore: invalid_use_of_visible_for_testing_member
    card.now = _now;
    _occupiedCards[reader] = card;
    // Capture the card's UID as the identity baseline so a later swap (a
    // different card seated without an intervening empty tick) is detected
    // as a change rather than "still the same card present". Routed through
    // the card (not the raw platform) so it's serialized with any other
    // transceive already in flight on this card.
    try {
      _occupiedUid[reader] = await card.transceive(_probeApdu) ?? '';
      nfcLog('reader "$reader": Get-UID baseline = ${_occupiedUid[reader]}');
    } catch (error) {
      _occupiedUid[reader] = ''; // card doesn't answer the probe (e.g. Type B)
      nfcLog('reader "$reader": Get-UID probe unanswered ($error) -- '
          'falling back to presence-only removal detection');
    }
    try {
      final driver = await identifyTag(card);
      nfcLog('reader "$reader": IDENTIFIED as ${driver.runtimeType}');
      _occupiedDrivers[reader] = _HeldDriver(driver);
      // ALWAYS emit on the one shared live pipeline. Each tags()/taggedTags()
      // subscription that actually forwards this event to its consumer marks
      // the held driver delivered (see taggedTags); if no subscription's
      // filter matches (or nobody is listening), `delivered` stays false and
      // the first later matching subscriber gets it via replay -- a filtered
      // pipeline discarding the event can no longer strand the presentation.
      _liveTaggedController.add(ReaderTaggedDriver(reader, driver));
    } catch (error, stackTrace) {
      // Connected but couldn't identify the card -- keep the reader marked
      // occupied (a card IS physically seated) and keep the loop going, but
      // surface the failure to tags()/taggedTags() consumers as a stream
      // error (matching AndroidNfcSource, which addErrors on a discovery it
      // cannot identify): the README error contract promises onError sees
      // "a tag that connects but fails identification". Errors are not
      // held/replayed -- with nobody listening, only the log remains.
      nfcLog(
        'Failed to identify tag on reader "$reader": $error',
        error: error,
        stackTrace: stackTrace,
      );
      _taggedTagsController?.addError(error, stackTrace);
    }
    return true;
  }

  /// Probes an **occupied** reader for continued presence of the SAME card.
  /// Returns true if the same card is still there; false (and flips the
  /// reader back to empty, disconnecting) if the card was removed OR a
  /// different card was swapped in (its UID changed) -- in both cases the
  /// next tick freshly connects and identifies whatever is now present,
  /// rather than leaving the previous card's driver/data in place.
  ///
  /// The recent-activity skip below narrows -- but does not eliminate --
  /// the probe-mid-conversation risk (F3's residual): a single in-flight
  /// frame that outlasts [pollInterval] since [ReaderCard.lastActivity] can
  /// still let a tick enqueue a probe that lands between two chained frames
  /// of the app's command sequence (the per-card serialization only orders
  /// it after the frame in flight, not after the whole sequence).
  Future<bool> _probeStillPresent(String reader) async {
    final card = _occupiedCards[reader];
    // Recent app traffic already proves the card is present -- and injecting
    // a probe APDU mid-conversation can abort a chained command. Skip.
    final last = card?.lastActivity;
    if (last != null && _now().difference(last) < pollInterval) return true;

    final String? response;
    try {
      response = card == null
          ? await _platform.transceive(reader, _probeApdu)
          : await card.transceive(_probeApdu);
    } catch (error) {
      // Nothing answers the probe -- the card was removed.
      nfcLog(
          'reader "$reader": liveness probe failed ($error) -- card removed');
      await _markCardGone(reader);
      return false;
    }
    final baseline = _occupiedUid[reader];
    if (baseline != null && baseline.isNotEmpty && response != baseline) {
      // A DIFFERENT card is now seated (its Get-UID response changed).
      nfcLog('reader "$reader": UID changed ($baseline -> $response) -- '
          'a different card was swapped in');
      await _markCardGone(reader);
      return false;
    }
    return true;
  }

  /// Logs a connect() failure for [reader] only when its message differs from
  /// the last one logged for that reader -- an empty reader produces the same
  /// failure on every 500ms tick, and logging all of them buries everything
  /// else.
  void _logConnectFailure(String reader, String message) {
    if (_lastConnectFailure[reader] == message) return;
    _lastConnectFailure[reader] = message;
    nfcLog('reader "$reader": connect() failed -- $message '
        '(expected while no card is seated; repeats are not logged)');
  }

  /// Flips [reader] back to empty and releases its card: clears the held
  /// driver and UID baseline SYNCHRONOUSLY (before the disconnect await, so a
  /// listener attaching mid-disconnect can't replay a driver for a card that
  /// is already gone), then disconnects. The next tick re-detects whatever is
  /// present now.
  Future<void> _markCardGone(String reader) async {
    nfcLog('reader "$reader": card GONE -- back to empty');
    _status[reader] = _ReaderStatus.empty;
    _occupiedDrivers.remove(reader);
    _occupiedCards.remove(reader);
    _occupiedUid.remove(reader);
    await _disconnectQuietly(reader);
  }

  /// Releases the connection held for [reader]'s card. Best-effort: a
  /// disconnect on a card/reader that is already gone can itself throw, and
  /// that must never break the poll loop -- log and move on.
  Future<void> _disconnectQuietly(String reader) async {
    try {
      await _platform.disconnect(reader);
    } catch (error, stackTrace) {
      nfcLog(
        'disconnect() failed for reader "$reader": $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _emitStates() {
    final states = [
      for (final entry in _status.entries)
        ExternalReaderState(entry.key, entry.value == _ReaderStatus.occupied),
    ];
    // This is what drives the status bar's filled/hollow dot. If the dot never
    // fills, compare these lines against the connect() outcomes above.
    nfcLog('emit readerStates: $states '
        '(listeners: ${_statesController?.hasListener ?? false})');
    _statesController?.add(states);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    // Clear each held driver SYNCHRONOUSLY before awaiting its disconnect --
    // same invariant as _probeStillPresent / the vanished-reader branch: a
    // listener attaching mid-disconnect must never replay a driver for a card
    // that is already being torn down.
    _occupiedDrivers.clear();
    _occupiedCards.clear();
    _occupiedUid.clear();
    for (final entry in _status.entries) {
      if (entry.value == _ReaderStatus.occupied) {
        await _disconnectQuietly(entry.key);
      }
    }
    await _taggedTagsController?.close();
    await _statesController?.close();
  }
}
