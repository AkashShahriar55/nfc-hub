import 'dart:async';
import 'dart:developer' as developer;

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
  String toString() =>
      'ExternalReaderState($name, cardPresent: $cardPresent)';
}

/// Whether a tracked reader currently has no card seated ([empty]), or has
/// a card connected and already identified ([occupied]).
enum _ReaderStatus { empty, occupied }

/// A [TagDriver] paired with the name of the CCID reader that produced it.
///
/// [CcidSource] itself has no notion of "filtering" -- that's Task 7's
/// concern (`NfcHub.tagStream(from: CcidSourceFilter.reader(...))`). This
/// type exists purely so a consumer of [CcidSource.taggedTags] can tell
/// which reader each driver came from without [CcidSource] needing to know
/// about filters at all.
class ReaderTaggedDriver {
  const ReaderTaggedDriver(this.reader, this.driver);

  /// The reader's name, exactly as reported by [NfcHubPlatform.listReaders].
  final String reader;

  final TagDriver driver;
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
///  - **occupied**: sends the harmless [_probeApdu] via
///    [NfcHubPlatform.transceive] as a liveness check. Success means the
///    same card is still seated -- nothing is re-emitted (a card that stays
///    put emits exactly once). A throw means the card was removed -- the
///    reader moves back to **empty**, [NfcHubPlatform.disconnect] releases
///    the connection the emitted [TagDriver] was holding, and the next
///    tick's empty-handling can pick up a re-insertion.
///
/// [tags], [taggedTags], and [readerStates] share one listener count, and
/// the connect/identify/emit path runs whenever ANY of them is listening.
/// So an app can listen to [readerStates] (via `NfcHub.connectionState()`)
/// BEFORE [tags] (via `NfcHub.tagStream()`) -- e.g. a status bar wired up
/// before the user hits "read" -- and a card seated in that window would be
/// identified while nothing is listening to [tags] yet. To avoid losing
/// that card, [CcidSource] holds the built [TagDriver] for every
/// **occupied** reader in [_occupiedDrivers], and [tags]/[taggedTags] are
/// built with [Stream.multi]: each NEW subscription first synchronously
/// replays the drivers currently held for occupied readers, then forwards
/// everything the live poll loop emits from that point on. `Stream.multi`
/// runs its callback once per subscription (unlike `.broadcast()`, whose
/// `add` always reaches every current listener at once), so the replay
/// only ever reaches the newly-attached subscriber -- listeners already
/// attached see nothing extra, and a card that stays put still emits
/// exactly once to any listener that was already there when it arrived.
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
  });

  final NfcHubPlatform _platform;
  final Duration pollInterval;

  StreamController<TagDriver>? _tagsController;
  StreamController<ReaderTaggedDriver>? _taggedTagsController;
  StreamController<List<ExternalReaderState>>? _statesController;
  Timer? _timer;
  int _listenerCount = 0;
  bool _ticking = false;

  final Map<String, _ReaderStatus> _status = {};

  /// The built [TagDriver] for every currently-**occupied** reader, keyed by
  /// reader name. Populated the instant [_tryConnect] identifies a newly
  /// seated card, and cleared the instant that reader goes back to
  /// **empty** (probe failure, vanish, or [dispose]). This is the source of
  /// truth [tags]/[taggedTags] replay to a subscriber that attaches after
  /// the card was already identified -- see the class doc for why.
  final Map<String, TagDriver> _occupiedDrivers = {};

  @override
  Stream<TagDriver> tags() {
    // Stream.multi (isBroadcast: true) invokes this callback once per
    // subscription, each with its OWN controller -- unlike a plain
    // `.broadcast()` stream where a single `add` reaches every listener at
    // once. That per-subscription isolation is what lets a NEW listener
    // replay the currently-occupied readers' drivers without those events
    // also reaching listeners that were already attached.
    return Stream<TagDriver>.multi((controller) {
      for (final driver in _occupiedDrivers.values) {
        controller.add(driver);
      }
      final live = (_tagsController ??= StreamController<TagDriver>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      ))
          .stream
          .listen(controller.add,
              onError: controller.addError, onDone: controller.close);
      controller.onCancel = live.cancel;
    }, isBroadcast: true);
  }

  /// The same tags as [tags], but paired with the reader that produced each
  /// one -- see [ReaderTaggedDriver]. Used by Task 7's unified stream to
  /// implement `CcidSourceFilter.reader(name)`.
  ///
  /// See [tags] for why this is built as a [Stream.multi]: it replays the
  /// currently-occupied readers' drivers to each new subscriber only.
  Stream<ReaderTaggedDriver> taggedTags() {
    return Stream<ReaderTaggedDriver>.multi((controller) {
      for (final entry in _occupiedDrivers.entries) {
        controller.add(ReaderTaggedDriver(entry.key, entry.value));
      }
      final live = (_taggedTagsController ??=
              StreamController<ReaderTaggedDriver>.broadcast(
        onListen: _onListen,
        onCancel: _onCancel,
      ))
          .stream
          .listen(controller.add,
              onError: controller.addError, onDone: controller.close);
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
      _timer = Timer.periodic(pollInterval, (_) => unawaited(_tick()));
    }
  }

  void _onCancel() {
    _listenerCount--;
    if (_listenerCount <= 0) {
      _listenerCount = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _tick() async {
    // A previous tick may still be in flight (e.g. a slow connect()) --
    // never run two ticks concurrently against the same reader state.
    if (_ticking) return;
    _ticking = true;
    try {
      await _pollOnce();
    } catch (error, stackTrace) {
      // Never let one bad poll tear down the timer -- log and try again
      // next tick, mirroring AndroidNfcSource's per-discovery isolation.
      developer.log(
        'CcidSource poll tick failed: $error',
        name: 'nfc_hub.CcidSource',
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
      developer.log(
        'listReaders() failed: $error',
        name: 'nfc_hub.CcidSource',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }

    final readerSet = readers.toSet();
    var changed = false;

    // Drop tracking for readers that vanished (unplugged) since last tick.
    final vanished =
        _status.keys.where((r) => !readerSet.contains(r)).toList();
    for (final reader in vanished) {
      final wasOccupied = _status[reader] == _ReaderStatus.occupied;
      _status.remove(reader);
      changed = true;
      // The reader itself is gone, so any connection held for its card is
      // no longer reachable through it -- release the handle rather than
      // leaking it (Android: an unclosed USB device handle; PC/SC: a Card
      // whose context.release() would otherwise never fire).
      if (wasOccupied) {
        // Clear the held driver SYNCHRONOUSLY, before the disconnect await --
        // otherwise a listener attaching to tags()/taggedTags() during that
        // await window replays a driver for a card that is already gone,
        // over a connection that is mid-teardown.
        _occupiedDrivers.remove(reader);
        await _disconnectQuietly(reader);
      }
    }

    // Start tracking newly-seen readers as empty.
    for (final reader in readers) {
      if (!_status.containsKey(reader)) {
        _status[reader] = _ReaderStatus.empty;
        changed = true;
      }
    }

    for (final reader in readers) {
      final status = _status[reader];
      if (status == _ReaderStatus.empty) {
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
    final CcidCard card;
    try {
      card = await _platform.connect(reader);
    } catch (_) {
      return false; // No card seated yet -- stays empty, nothing to report.
    }

    _status[reader] = _ReaderStatus.occupied;
    try {
      final driver = await identifyTag(card);
      _occupiedDrivers[reader] = driver;
      _tagsController?.add(driver);
      _taggedTagsController?.add(ReaderTaggedDriver(reader, driver));
    } catch (error, stackTrace) {
      // Connected but couldn't identify the card -- keep the reader marked
      // occupied (a card IS physically seated); log and move on, same as
      // AndroidNfcSource does for one bad discovery.
      developer.log(
        'Failed to identify tag on reader "$reader": $error',
        name: 'nfc_hub.CcidSource',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return true;
  }

  /// Probes an **occupied** reader for continued card presence. Returns
  /// true if the card is still there; false (and flips the reader back to
  /// empty) if the probe failed, meaning the card was removed.
  Future<bool> _probeStillPresent(String reader) async {
    try {
      await _platform.transceive(reader, _probeApdu);
      return true;
    } catch (_) {
      _status[reader] = _ReaderStatus.empty;
      // Clear the held driver SYNCHRONOUSLY with the status flip, before the
      // disconnect await -- otherwise a listener attaching mid-disconnect
      // replays a driver for a card that is already gone.
      _occupiedDrivers.remove(reader);
      // The card is gone -- release the connection the emitted TagDriver
      // was holding open for reads. Never called while still occupied: a
      // still-present card must keep its connection alive for the app's
      // in-flight reads.
      await _disconnectQuietly(reader);
      return false;
    }
  }

  /// Releases the connection held for [reader]'s card. Best-effort: a
  /// disconnect on a card/reader that is already gone can itself throw, and
  /// that must never break the poll loop -- log and move on.
  Future<void> _disconnectQuietly(String reader) async {
    try {
      await _platform.disconnect(reader);
    } catch (error, stackTrace) {
      developer.log(
        'disconnect() failed for reader "$reader": $error',
        name: 'nfc_hub.CcidSource',
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
    _statesController?.add(states);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    for (final entry in _status.entries) {
      if (entry.value == _ReaderStatus.occupied) {
        await _disconnectQuietly(entry.key);
      }
    }
    _occupiedDrivers.clear();
    await _tagsController?.close();
    await _taggedTagsController?.close();
    await _statesController?.close();
  }
}
