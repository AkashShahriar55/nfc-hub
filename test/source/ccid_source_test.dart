import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/source/ccid_source.dart';

/// Real NTAG213/Ultralight-shaped ATR, lifted from
/// `test/tag/detection_test.dart`: shared PC/SC Part 3 RID
/// A0 00 00 03 06, standard byte 0x03, card-name byte 0x03 (Type 2). This
/// resolves to a [Type2Tag] via `identifyTag`'s ATR fast path with zero
/// `transceive` calls -- so [_FakePlatform] only needs to answer
/// [CcidSource]'s own liveness probe, never anything `identifyTag` sends.
final _type2Atr = Uint8List.fromList([
  0x3B, 0x8F, 0x80, 0x01, //
  0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
]);

/// Scriptable fake of [NfcHubPlatform]'s CCID surface, shaped after the
/// fakes in `test/transport/ccid_backend_test.dart` and
/// `test/tag/detection_test.dart`: [readers] and [cardsPresent] are mutable
/// fields a test flips between [FakeAsync.elapse] calls to simulate a
/// reader/card changing state from one poll tick to the next.
class _FakePlatform extends NfcHubPlatform {
  /// The readers currently attached, as `listReaders()` would report them.
  List<String> readers = [];

  /// The subset of [readers] that currently have a card seated. `connect()`
  /// succeeds only for a reader in this set; `transceive()` (CcidSource's
  /// removal probe) only succeeds for a reader in this set too.
  final Set<String> cardsPresent = {};

  final List<String> listReadersLog = [];
  final List<String> connectLog = [];
  final List<String> transceiveLog = [];
  final List<String> disconnectLog = [];

  /// When set, [disconnect] throws this instead of returning -- used to
  /// verify a throwing disconnect doesn't break the poll loop.
  Object? disconnectError;

  @override
  Future<List<String>> listReaders() async {
    listReadersLog.add('listReaders');
    return List.of(readers);
  }

  @override
  Future<CcidCard> connect(String reader) async {
    connectLog.add(reader);
    if (!cardsPresent.contains(reader)) {
      throw Exception('no card seated in $reader');
    }
    return CcidCard(reader, atr: _type2Atr);
  }

  @override
  Future<String?> transceive(String reader, String capdu) async {
    transceiveLog.add(reader);
    if (!cardsPresent.contains(reader)) {
      throw Exception('card removed from $reader');
    }
    return '9000';
  }

  @override
  Future<void> disconnect(String reader) async {
    disconnectLog.add(reader);
    if (disconnectError != null) throw disconnectError!;
  }
}

void main() {
  group('CcidSource', () {
    test(
        'a reader appearing with a card emits a TagDriver and marks '
        'readerStates cardPresent: true after one poll interval', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        final states = <List<ExternalReaderState>>[];
        source.tags().listen(drivers.add);
        source.readerStates().listen(states.add);

        async.elapse(const Duration(milliseconds: 500));

        expect(drivers, hasLength(1));
        expect(drivers.single, isA<Type2Tag>());
        expect(states.last, [const ExternalReaderState('reader-1', true)]);
      });
    });

    test(
        'a held card removed (probe throws) flips readerStates to '
        'cardPresent: false, and a later re-insertion emits a NEW '
        'TagDriver', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        final states = <List<ExternalReaderState>>[];
        source.tags().listen(drivers.add);
        source.readerStates().listen(states.add);

        // Tick 1: card seated -> connect succeeds -> emits, occupied.
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));
        expect(states.last, [const ExternalReaderState('reader-1', true)]);

        // Card is pulled: the next status probe throws.
        platform.cardsPresent.remove('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1), reason: 'no re-emit for the removal');
        expect(states.last, [const ExternalReaderState('reader-1', false)]);

        // A new card is seated: connect succeeds again.
        platform.cardsPresent.add('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(2), reason: 'the re-insertion is a NEW tag');
        expect(drivers.last, isA<Type2Tag>());
        expect(states.last, [const ExternalReaderState('reader-1', true)]);
      });
    });

    test('a card that stays put across several ticks emits exactly once '
        '(dedup)', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);

        async.elapse(const Duration(seconds: 3)); // several 500ms ticks

        expect(drivers, hasLength(1));
      });
    });

    test('no listeners: listReaders() is never called (loop idle)', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        async.elapse(const Duration(seconds: 5));

        expect(platform.listReadersLog, isEmpty);
      });
    });

    test(
        'a reader that vanishes from listReaders while occupied is dropped '
        'from readerStates, and the loop keeps going', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        final states = <List<ExternalReaderState>>[];
        source.tags().listen(drivers.add);
        source.readerStates().listen(states.add);

        // Tick 1: seated card connects and is identified.
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));

        // The reader is unplugged entirely.
        platform.readers = [];
        platform.cardsPresent.clear();
        expect(() => async.elapse(const Duration(milliseconds: 500)),
            returnsNormally);
        expect(states.last, isEmpty);

        // The loop is still alive: plugging a (possibly different) reader
        // back in still works.
        platform.readers = ['reader-2'];
        platform.cardsPresent.add('reader-2');
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(2));
        expect(states.last, [const ExternalReaderState('reader-2', true)]);
      });
    });

    test('a connect() that throws (empty reader, no card) does not emit or '
        'crash, and the next tick still polls', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()..readers = ['reader-1'];
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);

        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, isEmpty);
        expect(platform.connectLog, ['reader-1']);

        // Next tick still polls (connect attempted again).
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, isEmpty);
        expect(platform.connectLog, ['reader-1', 'reader-1']);
      });
    });

    test(
        'a held card removed (probe throws) calls disconnect() exactly '
        'once, and a re-insertion connects again without a second '
        'disconnect', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        source.tags().listen((_) {});

        // Tick 1: card seated -> connect succeeds, no disconnect yet.
        async.elapse(const Duration(milliseconds: 500));
        expect(platform.connectLog, ['reader-1']);
        expect(platform.disconnectLog, isEmpty);

        // Card pulled: the next probe throws -> disconnect() called once.
        platform.cardsPresent.remove('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        expect(platform.disconnectLog, ['reader-1']);

        // Still empty: the reader keeps retrying connect() every tick (as
        // covered by the existing "connect() that throws" test), but that
        // must never trigger another disconnect.
        async.elapse(const Duration(milliseconds: 500));
        expect(platform.disconnectLog, ['reader-1']);

        // Re-insertion: connect() succeeds again (2nd successful connect),
        // and no new disconnect happens while the new card is held.
        platform.cardsPresent.add('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        expect(platform.connectLog, ['reader-1', 'reader-1', 'reader-1'],
            reason: 'tick1 connect, tick3 failed retry, tick4 reconnect');
        expect(platform.disconnectLog, ['reader-1'],
            reason: 'disconnect count stays 1 while the new card is held');
      });
    });

    test(
        'a reader that vanishes while occupied disconnects it before '
        'dropping it from tracking', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        source.tags().listen((_) {});

        // Tick 1: card seated and connected.
        async.elapse(const Duration(milliseconds: 500));
        expect(platform.connectLog, ['reader-1']);
        expect(platform.disconnectLog, isEmpty);

        // The reader is unplugged entirely (not just the card removed).
        platform.readers = [];
        platform.cardsPresent.clear();
        async.elapse(const Duration(milliseconds: 500));

        expect(platform.disconnectLog, ['reader-1']);
      });
    });

    test('dispose() while a card is occupied disconnects it', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);

        source.tags().listen((_) {});

        // Tick 1: card seated and connected.
        async.elapse(const Duration(milliseconds: 500));
        expect(platform.connectLog, ['reader-1']);
        expect(platform.disconnectLog, isEmpty);

        source.dispose();
        async.flushMicrotasks();

        expect(platform.disconnectLog, ['reader-1']);
      });
    });

    test(
        'a disconnect() that itself throws does not break the loop -- the '
        'next tick still runs', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);

        // Tick 1: card seated and connected.
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));

        // Card pulled, and disconnect() itself throws.
        platform.cardsPresent.remove('reader-1');
        platform.disconnectError = Exception('disconnect failed');
        expect(
          () => async.elapse(const Duration(milliseconds: 500)),
          returnsNormally,
        );
        expect(platform.disconnectLog, ['reader-1']);

        // The loop is still alive: the next tick still polls and a
        // re-insertion is picked up normally.
        platform.disconnectError = null;
        platform.cardsPresent.add('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(2));
      });
    });

    test(
        'per-reader isolation: one reader whose connect() throws does not '
        "abort the tick -- the other reader's card still emits and shows "
        'cardPresent: true', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-empty', 'reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        final states = <List<ExternalReaderState>>[];
        source.tags().listen(drivers.add);
        source.readerStates().listen(states.add);

        async.elapse(const Duration(milliseconds: 500));

        expect(drivers, hasLength(1));
        expect(drivers.single, isA<Type2Tag>());
        expect(
          states.last,
          containsAll(<ExternalReaderState>[
            const ExternalReaderState('reader-1', true),
            const ExternalReaderState('reader-empty', false),
          ]),
        );
      });
    });

    test(
        'a card present before tags() is listened is delivered to a late '
        'tags() subscriber (readerStates was already driving the loop)', () {
      // Regression: connectionState() (readerStates) listened first must
      // not consume the card such that a later tagStream() (tags) never
      // sees it.
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        // Only readerStates is listened first (what connectionState does).
        final states = <List<ExternalReaderState>>[];
        final stateSub = source.readerStates().listen(states.add);
        async.elapse(const Duration(milliseconds: 1500)); // a few ticks
        expect(states.last, [const ExternalReaderState('reader-1', true)]);

        // Now the app starts tagStream().
        final tags = <TagDriver>[];
        final tagSub = source.tags().listen(tags.add);
        async.elapse(const Duration(milliseconds: 500));

        expect(tags, isNotEmpty,
            reason: 'the card present when tags() started listening must '
                'be delivered to it');
        stateSub.cancel();
        tagSub.cancel();
      });
    });

    test(
        'a card present before taggedTags() is listened is delivered to a '
        'late taggedTags() subscriber, tagged with its reader', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final stateSub = source.readerStates().listen((_) {});
        async.elapse(const Duration(milliseconds: 1500));

        final tagged = <ReaderTaggedDriver>[];
        final taggedSub = source.taggedTags().listen(tagged.add);
        async.elapse(const Duration(milliseconds: 500));

        expect(tagged, hasLength(1));
        expect(tagged.single.reader, 'reader-1');
        stateSub.cancel();
        taggedSub.cancel();
      });
    });

    test(
        'a late tags() listener does NOT re-deliver to a listener already '
        'attached from the start (no double emit)', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final firstDrivers = <TagDriver>[];
        final firstSub = source.tags().listen(firstDrivers.add);
        async.elapse(const Duration(milliseconds: 500));
        expect(firstDrivers, hasLength(1));

        // A second, late listener joins after the card is already occupied.
        final secondDrivers = <TagDriver>[];
        final secondSub = source.tags().listen(secondDrivers.add);
        async.elapse(const Duration(milliseconds: 500));

        expect(secondDrivers, hasLength(1),
            reason: 'the late listener gets the replay exactly once');
        expect(firstDrivers, hasLength(1),
            reason:
                'the listener already attached must not be re-delivered to');
        firstSub.cancel();
        secondSub.cancel();
      });
    });

    test(
        "tick overlap guard: a tick whose async work outlives one poll "
        'interval is not double-run by an overlapping tick -- the reader '
        'is connected and emitted exactly once', () {
      FakeAsync().run((async) {
        final platform = _SlowConnectFakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);

        // The first tick's listReaders() call is now in flight, held open
        // by platform.hold. Elapse past several poll intervals' worth of
        // fake time while that first tick is still pending: if the
        // `_ticking` guard didn't work, each of these ticks would start
        // its OWN listReaders() call concurrently, bumping callCount past
        // 1 -- even though every call (old or new) would equally be stuck
        // awaiting the same still-incomplete `hold`.
        async.elapse(const Duration(milliseconds: 1600));
        expect(platform.callCount, 1,
            reason:
                'only the first tick ever entered listReaders() -- the '
                'guard must have skipped every overlapping tick attempt '
                'before it got this far');
        expect(platform.connectLog, isEmpty);

        // Let the first (and only) tick's listReaders() -- and everything
        // after it -- complete.
        platform.hold.complete();
        async.elapse(const Duration(milliseconds: 500));

        expect(platform.connectLog, ['reader-1']);
        expect(drivers, hasLength(1));
      });
    });
  });
}

/// A [_FakePlatform] whose [listReaders] doesn't complete until [hold] is
/// completed -- used to hold a tick's async work open across multiple
/// [FakeAsync.elapse] calls, so a test can assert the `_ticking` guard
/// prevents an overlapping second tick from starting concurrently.
class _SlowConnectFakePlatform extends _FakePlatform {
  final Completer<void> hold = Completer<void>();

  /// Incremented the instant [listReaders] is entered, BEFORE awaiting
  /// [hold] -- unlike [listReadersLog] (only appended after the await
  /// resolves), this distinguishes "no overlapping call was ever attempted"
  /// from "an overlapping call was attempted and is also stuck on `hold`",
  /// which would otherwise look identical from the log alone.
  int callCount = 0;

  @override
  Future<List<String>> listReaders() async {
    callCount++;
    await hold.future;
    return super.listReaders();
  }
}
