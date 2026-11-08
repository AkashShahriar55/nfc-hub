import 'dart:async';

import 'package:flutter/foundation.dart';

import 'platform/android_nfc_manager.dart';
import 'source/android_source.dart';
import 'source/ccid_source.dart';
import 'tag/tag_driver.dart';

/// Restricts [NfcHub.tagStream]/[NfcHub.readTag] (see `nfc_hub_base.dart`)
/// to a single tag source, so an app that knows which reader/antenna it
/// wants can narrow the merged stream without giving up seamlessness for
/// everyone else -- the default (`null`, or omitting `from` entirely) still
/// yields every source merged.
@immutable
class NfcSource {
  /// Restricts to tags discovered by the phone's built-in NFC antenna.
  const NfcSource.builtIn()
      : _builtInNfc = true,
        _readerName = null;

  /// Restricts to tags read through the named CCID/PC-SC reader, exactly as
  /// reported by [NfcHub.listReaders]/`NfcHubPlatform.listReaders`.
  const NfcSource.reader(String name)
      : _builtInNfc = false,
        _readerName = name;

  final bool _builtInNfc;
  final String? _readerName;

  @override
  bool operator ==(Object other) =>
      other is NfcSource &&
      other._builtInNfc == _builtInNfc &&
      other._readerName == _readerName;

  @override
  int get hashCode => Object.hash(_builtInNfc, _readerName);

  @override
  String toString() =>
      _builtInNfc ? 'NfcSource.builtIn()' : 'NfcSource.reader($_readerName)';
}

/// Why the phone's built-in NFC antenna is unavailable, as surfaced on
/// [NfcConnectionState.builtInNfcReason]. [none] when it IS available.
enum NfcUnavailableReason {
  /// The antenna is available -- [NfcConnectionState.builtInNfcAvailable]
  /// is true.
  none,

  /// The device has no NFC hardware at all.
  noHardware,

  /// NFC hardware is present but the user has turned it off.
  disabled,
}

/// The combined connection state [NfcHub.connectionState] emits: whether
/// the phone's built-in NFC antenna is available, and the live per-reader
/// presence of every attached CCID/PC-SC reader.
@immutable
class NfcConnectionState {
  const NfcConnectionState({
    required this.builtInNfcAvailable,
    required this.builtInNfcReason,
    required this.externalReaders,
  });

  /// Whether the phone's built-in NFC antenna can be used right now.
  final bool builtInNfcAvailable;

  /// Why it can't, when [builtInNfcAvailable] is false; [NfcUnavailableReason.none]
  /// when it's available.
  final NfcUnavailableReason builtInNfcReason;

  /// The current `{name, cardPresent}` state of every CCID/PC-SC reader
  /// [CcidSource] can see, mirroring `CcidSource.readerStates()`.
  final List<ExternalReaderState> externalReaders;

  @override
  bool operator ==(Object other) =>
      other is NfcConnectionState &&
      other.builtInNfcAvailable == builtInNfcAvailable &&
      other.builtInNfcReason == builtInNfcReason &&
      listEquals(other.externalReaders, externalReaders);

  @override
  int get hashCode => Object.hash(
        builtInNfcAvailable,
        builtInNfcReason,
        Object.hashAll(externalReaders),
      );

  @override
  String toString() => 'NfcConnectionState(builtInNfcAvailable: '
      '$builtInNfcAvailable, builtInNfcReason: $builtInNfcReason, '
      'externalReaders: $externalReaders)';
}

/// Merges [androidSource] and [ccidSource] into the one [TagDriver] stream
/// `NfcHub.tagStream` exposes.
///
/// With no [filter] (the default), both sources are subscribed to on
/// listen and both cancelled once the last listener of the returned stream
/// cancels -- so an app consuming the merged stream never has to know, or
/// care, which underlying source is doing the work. A [filter] narrows to
/// exactly one source, and only that source is ever started:
///
///  - [NfcSource.builtIn]: only [androidSource.tags] is
///    subscribed.
///  - [NfcSource.reader]: only [ccidSource.taggedTags] is
///    subscribed, filtered down to the named reader.
Stream<TagDriver> mergeTagStreams({
  required AndroidNfcSource androidSource,
  required CcidSource ccidSource,
  NfcSource? filter,
}) {
  late final StreamController<TagDriver> controller;
  final subs = <StreamSubscription<Object?>>[];

  void start() {
    if (filter == null) {
      subs.add(androidSource
          .tags()
          .listen(controller.add, onError: controller.addError));
      subs.add(ccidSource
          .tags()
          .listen(controller.add, onError: controller.addError));
    } else if (filter._builtInNfc) {
      subs.add(androidSource
          .tags()
          .listen(controller.add, onError: controller.addError));
    } else {
      // Filter INSIDE CcidSource (not downstream here): the source only
      // marks a held presentation delivered when a subscription actually
      // forwards it, so a session filtered to one reader can never consume
      // -- and permanently strand -- another reader's card.
      subs.add(ccidSource.taggedTags(reader: filter._readerName).listen(
            (tagged) => controller.add(tagged.driver),
            onError: controller.addError,
          ));
    }
  }

  Future<void> stop() async {
    final toCancel = subs.toList();
    subs.clear();
    for (final sub in toCancel) {
      await sub.cancel();
    }
  }

  controller = StreamController<TagDriver>.broadcast(
    onListen: start,
    onCancel: stop,
  );
  return controller.stream;
}

/// Combines [manager]'s built-in-NFC availability with [ccidSource]'s
/// per-reader presence into the one [NfcConnectionState] stream
/// `NfcHub.connectionState` exposes.
///
/// On listen: fetches the current [NfcState] via [manager.getNfcState],
/// subscribes to further changes via [manager.nfcStateChanges], and
/// subscribes to [ccidSource.readerStates] -- emitting a fresh
/// [NfcConnectionState] whenever either side changes. Both subscriptions
/// are cancelled once the last listener of the returned stream cancels.
Stream<NfcConnectionState> combineConnectionState({
  required AndroidNfcManager manager,
  required CcidSource ccidSource,
}) {
  late final StreamController<NfcConnectionState> controller;
  StreamSubscription<NfcState>? nfcSub;
  StreamSubscription<List<ExternalReaderState>>? readerSub;

  var builtInAvailable = false;
  var builtInReason = NfcUnavailableReason.noHardware;
  var externalReaders = const <ExternalReaderState>[];

  void applyNfcState(NfcState state) {
    switch (state) {
      case NfcState.enabled:
        builtInAvailable = true;
        builtInReason = NfcUnavailableReason.none;
      case NfcState.disabled:
        builtInAvailable = false;
        builtInReason = NfcUnavailableReason.disabled;
      case NfcState.noHardware:
        builtInAvailable = false;
        builtInReason = NfcUnavailableReason.noHardware;
    }
  }

  void emit() {
    controller.add(NfcConnectionState(
      builtInNfcAvailable: builtInAvailable,
      builtInNfcReason: builtInReason,
      externalReaders: externalReaders,
    ));
  }

  Future<void> start() async {
    // Resolve the initial built-in-NFC state BEFORE wiring up the
    // emitting subscriptions below. Otherwise a CCID readerStates tick (or
    // an nfcStateChanges event) could fire -- and emit() -- while
    // builtInAvailable/builtInReason still held their hardcoded
    // (false/noHardware) defaults, handing the app a snapshot with correct
    // external-reader info but a wrong built-in-NFC verdict.
    try {
      applyNfcState(await manager.getNfcState());
    } catch (error, stackTrace) {
      controller.addError(error, stackTrace);
    }

    readerSub = ccidSource.readerStates().listen(
      (states) {
        externalReaders = states;
        emit();
      },
      onError: controller.addError,
    );

    nfcSub = manager.nfcStateChanges.listen(
      (state) {
        applyNfcState(state);
        emit();
      },
      onError: controller.addError,
    );

    emit();
  }

  Future<void> stop() async {
    await nfcSub?.cancel();
    await readerSub?.cancel();
    nfcSub = null;
    readerSub = null;
  }

  controller = StreamController<NfcConnectionState>.broadcast(
    onListen: () => unawaited(start()),
    onCancel: stop,
  );
  return controller.stream;
}
