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
class CcidSourceFilter {
  /// Restricts to tags discovered by the phone's built-in NFC antenna.
  const CcidSourceFilter.builtInNfc()
      : _builtInNfc = true,
        _readerName = null;

  /// Restricts to tags read through the named CCID/PC-SC reader, exactly as
  /// reported by [NfcHub.listReaders]/`NfcHubPlatform.listReaders`.
  const CcidSourceFilter.reader(String name)
      : _builtInNfc = false,
        _readerName = name;

  final bool _builtInNfc;
  final String? _readerName;

  @override
  bool operator ==(Object other) =>
      other is CcidSourceFilter &&
      other._builtInNfc == _builtInNfc &&
      other._readerName == _readerName;

  @override
  int get hashCode => Object.hash(_builtInNfc, _readerName);

  @override
  String toString() => _builtInNfc
      ? 'CcidSourceFilter.builtInNfc()'
      : 'CcidSourceFilter.reader($_readerName)';
}

/// Why the phone's built-in NFC antenna is unavailable, as surfaced on
/// [CcidConnectionState.builtInNfcReason]. [none] when it IS available.
enum NfcUnavailableReason {
  /// The antenna is available -- [CcidConnectionState.builtInNfcAvailable]
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
class CcidConnectionState {
  const CcidConnectionState({
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
      other is CcidConnectionState &&
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
  String toString() => 'CcidConnectionState(builtInNfcAvailable: '
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
///  - [CcidSourceFilter.builtInNfc]: only [androidSource.tags] is
///    subscribed.
///  - [CcidSourceFilter.reader]: only [ccidSource.taggedTags] is
///    subscribed, filtered down to the named reader.
Stream<TagDriver> mergeTagStreams({
  required AndroidNfcSource androidSource,
  required CcidSource ccidSource,
  CcidSourceFilter? filter,
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
      final readerName = filter._readerName;
      subs.add(ccidSource.taggedTags().listen(
        (tagged) {
          if (tagged.reader == readerName) controller.add(tagged.driver);
        },
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
    onCancel: () => unawaited(stop()),
  );
  return controller.stream;
}

/// Combines [manager]'s built-in-NFC availability with [ccidSource]'s
/// per-reader presence into the one [CcidConnectionState] stream
/// `NfcHub.connectionState` exposes.
///
/// On listen: fetches the current [NfcState] via [manager.getNfcState],
/// subscribes to further changes via [manager.nfcStateChanges], and
/// subscribes to [ccidSource.readerStates] -- emitting a fresh
/// [CcidConnectionState] whenever either side changes. Both subscriptions
/// are cancelled once the last listener of the returned stream cancels.
Stream<CcidConnectionState> combineConnectionState({
  required AndroidNfcManager manager,
  required CcidSource ccidSource,
}) {
  late final StreamController<CcidConnectionState> controller;
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
    controller.add(CcidConnectionState(
      builtInNfcAvailable: builtInAvailable,
      builtInNfcReason: builtInReason,
      externalReaders: externalReaders,
    ));
  }

  Future<void> start() async {
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

    try {
      applyNfcState(await manager.getNfcState());
    } catch (error, stackTrace) {
      controller.addError(error, stackTrace);
    }
    emit();
  }

  Future<void> stop() async {
    await nfcSub?.cancel();
    await readerSub?.cancel();
    nfcSub = null;
    readerSub = null;
  }

  controller = StreamController<CcidConnectionState>.broadcast(
    onListen: () => unawaited(start()),
    onCancel: () => unawaited(stop()),
  );
  return controller.stream;
}
