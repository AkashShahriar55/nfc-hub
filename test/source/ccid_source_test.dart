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

  /// The Get-UID probe response per reader. A test flips this (while the
  /// reader stays in [cardsPresent]) to simulate a DIFFERENT card swapped in
  /// without an intervening empty tick. Defaults to '9000' for a seated card.
  final Map<String, String> cardUid = {};

  /// Readers holding a card that connects but cannot be identified: connect()
  /// succeeds with an ATR-less [CcidCard], and every transceive throws -- so
  /// `identifyTag`'s probing chain deterministically ends in
  /// [UnrecognizedTagException]. Requires `NfcHubPlatform.instance` to be set
  /// to this fake, since the probes go through [CcidCard.transceive].
  final Set<String> muteCards = {};

  final List<String> listReadersLog = [];
  final List<String> connectLog = [];
  final List<String> transceiveLog = [];
  final List<String> disconnectLog = [];

  /// When set, [disconnect] throws this instead of returning -- used to
  /// verify a throwing disconnect doesn't break the poll loop.
  Object? disconnectError;

  /// When set, [disconnect] awaits this completer before proceeding (and
  /// before throwing [disconnectError], if also set) -- used to hold a
  /// disconnect open across a [FakeAsync.elapse] so a test can attach a new
  /// listener while the teardown is still in flight.
  Completer<void>? disconnectHold;

  @override
  Future<List<String>> listReaders() async {
    listReadersLog.add('listReaders');
    return List.of(readers);
  }

  @override
  Future<CcidCard> connect(String reader) async {
    connectLog.add(reader);
    if (muteCards.contains(reader)) return CcidCard(reader); // no ATR
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
    return cardUid[reader] ?? '9000';
  }

  @override
  Future<void> disconnect(String reader) async {
    disconnectLog.add(reader);
    if (disconnectHold != null) await disconnectHold!.future;
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
        // A fake clock that advances alongside async.elapse (see the
        // "liveness probe is SKIPPED" test below for why this is needed:
        // otherwise the activity-gated probe skip -- comparing against real
        // wall-clock time, which barely moves under FakeAsync -- would skip
        // the probe forever after the first connect and this test's removal
        // would never be detected).
        var fakeNow = DateTime(2026, 1, 1);
        final source = CcidSource(platform, now: () => fakeNow);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        final states = <List<ExternalReaderState>>[];
        source.tags().listen(drivers.add);
        source.readerStates().listen(states.add);

        // Tick 1: card seated -> connect succeeds -> emits, occupied.
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));
        expect(states.last, [const ExternalReaderState('reader-1', true)]);

        // Card is pulled: the next status probe throws.
        platform.cardsPresent.remove('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1), reason: 'no re-emit for the removal');
        expect(states.last, [const ExternalReaderState('reader-1', false)]);

        // A new card is seated: connect succeeds again.
        platform.cardsPresent.add('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
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

    test(
        'a DIFFERENT card swapped in (UID changed, no empty tick) is '
        're-identified rather than left showing the previous card', () {
      // Regression: the removal probe only checked presence, not identity, so
      // a fast A->B swap kept the reader "occupied" with A's driver -- the UI
      // showed the previous card's data for the newly-seated one.
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1')
          ..cardUid['reader-1'] = '04AABBCC9000'; // card A
        // Fake clock advanced alongside async.elapse -- see the "liveness
        // probe is SKIPPED" test for why this is required for the probe to
        // ever run again after the first connect.
        var fakeNow = DateTime(2026, 1, 1);
        final source = CcidSource(platform, now: () => fakeNow);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);

        async.elapse(const Duration(milliseconds: 500)); // card A detected
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));

        // Swap in a DIFFERENT card without an intervening empty tick: same
        // reader still has a card, but its Get-UID response changed.
        platform.cardUid['reader-1'] = '04DDEEFF9000'; // card B
        async.elapse(const Duration(milliseconds: 500)); // probe sees change
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        async.elapse(const Duration(milliseconds: 500)); // reconnect + identify
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));

        expect(drivers, hasLength(2),
            reason: 'the swapped-in card must be identified and emitted as a '
                'new driver, not left showing the previous card');
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
        // Fake clock advanced alongside async.elapse -- see the "liveness
        // probe is SKIPPED" test for why this is required for the probe to
        // ever run again after the first connect.
        var fakeNow = DateTime(2026, 1, 1);
        final source = CcidSource(platform, now: () => fakeNow);
        addTearDown(source.dispose);

        source.tags().listen((_) {});

        // Tick 1: card seated -> connect succeeds, no disconnect yet.
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(platform.connectLog, ['reader-1']);
        expect(platform.disconnectLog, isEmpty);

        // Card pulled: the next probe throws -> disconnect() called once.
        platform.cardsPresent.remove('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(platform.disconnectLog, ['reader-1']);

        // Still empty: the reader keeps retrying connect() every tick (as
        // covered by the existing "connect() that throws" test), but that
        // must never trigger another disconnect.
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(platform.disconnectLog, ['reader-1']);

        // Re-insertion: connect() succeeds again (2nd successful connect),
        // and no new disconnect happens while the new card is held.
        platform.cardsPresent.add('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
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
        // Fake clock advanced alongside async.elapse -- see the "liveness
        // probe is SKIPPED" test for why this is required for the probe to
        // ever run again after the first connect.
        var fakeNow = DateTime(2026, 1, 1);
        final source = CcidSource(platform, now: () => fakeNow);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);

        // Tick 1: card seated and connected.
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));

        // Card pulled, and disconnect() itself throws.
        platform.cardsPresent.remove('reader-1');
        platform.disconnectError = Exception('disconnect failed');
        expect(
          () => async.elapse(const Duration(milliseconds: 500)),
          returnsNormally,
        );
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(platform.disconnectLog, ['reader-1']);

        // The loop is still alive: the next tick still polls and a
        // re-insertion is picked up normally.
        platform.disconnectError = null;
        platform.cardsPresent.add('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
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
        'a late tags() listener does NOT get a card already delivered live '
        'to a listener attached from the start (exactly-once, not '
        'replay-to-every-listener)', () {
      // Regression for the exactly-once contract: this card was delivered
      // the moment it was identified (a tags() listener was already live),
      // so a late second listener must see nothing -- the OLD behavior
      // (replay to every NEW subscription regardless of prior delivery) is
      // exactly the double-read bug this contract kills.
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

        // A second, late listener joins after the card is already occupied
        // AND already delivered (live) to the first listener.
        final secondDrivers = <TagDriver>[];
        final secondSub = source.tags().listen(secondDrivers.add);
        async.elapse(const Duration(milliseconds: 500));

        expect(secondDrivers, isEmpty,
            reason: 'the card was already delivered live to the first '
                'listener -- the late listener must not replay it');
        expect(firstDrivers, hasLength(1),
            reason:
                'the listener already attached must not be re-delivered to');
        firstSub.cancel();
        secondSub.cancel();
      });
    });

    test(
        'a seated card is delivered exactly ONCE across resubscriptions: '
        'a second listener (or a re-listen) does not replay it', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final first = <TagDriver>[];
        final sub1 = source.tags().listen(first.add);
        async.elapse(const Duration(milliseconds: 500));
        expect(first, hasLength(1));

        // Simulates a widget rebuild / session restart: cancel and re-listen.
        sub1.cancel();
        final second = <TagDriver>[];
        source.tags().listen(second.add);
        async.elapse(const Duration(milliseconds: 1500));
        expect(second, isEmpty,
            reason: 'the same presentation must not be re-delivered');
      });
    });

    test(
        'a driver identified while only readerStates is listened is replayed '
        'to the FIRST tags() subscriber (and only that one)', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        source.readerStates().listen((_) {}); // starts the loop, holds driver
        async.elapse(const Duration(milliseconds: 500));

        final a = <TagDriver>[];
        final b = <TagDriver>[];
        source.tags().listen(a.add);
        source.tags().listen(b.add);
        async.elapse(const Duration(milliseconds: 500));
        expect(a.length + b.length, 1,
            reason: 'held driver replays to exactly one listener');
      });
    });

    test(
        'a card that connects but fails identification surfaces the error '
        "on the listener's onError, and the stream stays alive: a good "
        'card on another reader still delivers', () {
      // Regression (final review, Finding 2): the identify catch only
      // developer.log'ed, so an unidentifiable seated card was invisible to
      // the app -- contradicting the README error contract ("onError
      // receives ... a tag that connects but fails identification").
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-mute']
          ..muteCards.add('reader-mute');
        NfcHubPlatform.instance = platform;
        addTearDown(() => NfcHubPlatform.instance = null);
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        final errors = <Object>[];
        final taggedErrors = <Object>[];
        source.tags().listen(drivers.add, onError: errors.add);
        source.taggedTags().listen((_) {}, onError: taggedErrors.add);

        async.elapse(const Duration(milliseconds: 500));
        expect(errors, hasLength(1));
        expect(errors.single, isA<UnrecognizedTagException>());
        expect(taggedErrors, hasLength(1),
            reason: 'taggedTags() consumers must receive the error too');
        expect(drivers, isEmpty);

        // The stream survived: a good card on another reader still delivers.
        platform.readers = ['reader-mute', 'reader-good'];
        platform.cardsPresent.add('reader-good');
        async.elapse(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));
        expect(drivers.single, isA<Type2Tag>());
      });
    });

    test(
        'a reader-filtered taggedTags(reader: A) listener does NOT consume '
        "another reader's card: reader B's card is held for a LATER "
        'unfiltered subscriber', () {
      // Regression (final review, Finding 1): the old design marked
      // `delivered` the moment ANY listener existed, then filtered
      // downstream (in mergeTagStreams) -- so a session filtered to reader
      // A silently consumed and discarded reader B's card, permanently.
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-A', 'reader-B']
          ..cardsPresent.add('reader-B');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final filtered = <ReaderTaggedDriver>[];
        final filteredSub =
            source.taggedTags(reader: 'reader-A').listen(filtered.add);
        async.elapse(const Duration(milliseconds: 1500));
        expect(filtered, isEmpty,
            reason: "reader B's card must not reach a reader-A filter");

        // A later unfiltered subscriber must still receive B's card -- the
        // filtered pipeline never consumed it.
        final all = <TagDriver>[];
        final allSub = source.tags().listen(all.add);
        async.elapse(const Duration(milliseconds: 500));
        expect(all, hasLength(1),
            reason: "reader B's card was never delivered to any matching "
                'listener, so it must be replayed to the first unfiltered '
                'subscriber');
        filteredSub.cancel();
        allSub.cancel();
      });
    });

    test(
        'a reader-filtered taggedTags(reader: A) listener that DOES receive '
        "reader A's card consumes it: a later unfiltered subscriber does "
        'not get it again', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-A']
          ..cardsPresent.add('reader-A');
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        final filtered = <ReaderTaggedDriver>[];
        final filteredSub =
            source.taggedTags(reader: 'reader-A').listen(filtered.add);
        async.elapse(const Duration(milliseconds: 500));
        expect(filtered, hasLength(1));
        expect(filtered.single.reader, 'reader-A');

        final all = <TagDriver>[];
        final allSub = source.tags().listen(all.add);
        async.elapse(const Duration(milliseconds: 500));
        expect(all, isEmpty,
            reason: 'the card already reached the matching filtered '
                'listener -- it must not be replayed to a later subscriber');
        filteredSub.cancel();
        allSub.cancel();
      });
    });

    test(
        'replay to a late reader-filtered subscriber only hands over the '
        "matching reader's card, leaving the other held for its own "
        'consumer', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-A', 'reader-B']
          ..cardsPresent.addAll(['reader-A', 'reader-B']);
        final source = CcidSource(platform);
        addTearDown(source.dispose);

        // Only the loop-driving readerStates listener exists at identify
        // time -- both cards end up held and undelivered.
        source.readerStates().listen((_) {});
        async.elapse(const Duration(milliseconds: 500));

        final filtered = <ReaderTaggedDriver>[];
        source.taggedTags(reader: 'reader-A').listen(filtered.add);
        async.flushMicrotasks();
        expect(filtered, hasLength(1));
        expect(filtered.single.reader, 'reader-A');

        // Reader B's held card was NOT consumed by the reader-A replay scan.
        final late = <ReaderTaggedDriver>[];
        source.taggedTags().listen(late.add);
        async.flushMicrotasks();
        expect(late, hasLength(1));
        expect(late.single.reader, 'reader-B');
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

    test(
        'a late tags() listener attaching WHILE a removed card\'s '
        'disconnect() is still in flight does NOT get the stale driver '
        'replayed', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1')
          ..disconnectHold = Completer<void>();
        // Fake clock advanced alongside async.elapse -- see the "liveness
        // probe is SKIPPED" test for why this is required for the probe to
        // ever run again after the first connect.
        var fakeNow = DateTime(2026, 1, 1);
        final source = CcidSource(platform, now: () => fakeNow);
        addTearDown(source.dispose);

        // Tick 1: card seated -> connect succeeds -> emits, occupied.
        source.tags().listen((_) {});
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(platform.connectLog, ['reader-1']);

        // Card is pulled: the next probe throws, kicking off disconnect(),
        // which is held open by platform.disconnectHold.
        platform.cardsPresent.remove('reader-1');
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(platform.disconnectLog, ['reader-1'],
            reason: 'disconnect() has been called but not yet resolved');

        // A brand-new listener attaches WHILE that disconnect is still in
        // flight. It must see nothing replayed -- the reader's card is
        // already known-gone and its connection is mid-teardown.
        final lateDrivers = <TagDriver>[];
        final lateSub = source.tags().listen(lateDrivers.add);
        async.flushMicrotasks();
        expect(lateDrivers, isEmpty,
            reason: 'the stale driver must not be replayed while the '
                "reader's disconnect() is still in flight");

        // Let the disconnect resolve so the source can be torn down cleanly.
        platform.disconnectHold!.complete();
        async.elapse(const Duration(milliseconds: 500));
        lateSub.cancel();
      });
    });

    test(
        'the liveness probe is SKIPPED while the app is actively reading the '
        'card (recent CcidCard.transceive traffic proves presence)', () {
      FakeAsync().run((async) {
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        NfcHubPlatform.instance = platform;
        addTearDown(() => NfcHubPlatform.instance = null);

        var fakeNow = DateTime(2026, 1, 1);
        final source = CcidSource(platform, now: () => fakeNow);
        addTearDown(source.dispose);

        final drivers = <TagDriver>[];
        source.tags().listen(drivers.add);
        async.elapse(const Duration(milliseconds: 500));
        fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        expect(drivers, hasLength(1));

        // The identify path + UID baseline ran; note the probe count now.
        final probesAfterConnect = platform.transceiveLog.length;

        // Simulate the app reading the card continuously: a driver transceive
        // completes just before each tick.
        final card = (drivers.single as Type2Tag);
        for (var i = 0; i < 4; i++) {
          card.readUid(); // issues a transceive through the same CcidCard
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 500));
          fakeNow = fakeNow.add(const Duration(milliseconds: 500));
        }

        // Probes issued by the POLL LOOP during those 4 ticks: zero. All
        // transceives logged were the driver's own readUid calls.
        final pollProbes = platform.transceiveLog.length -
            probesAfterConnect -
            4; // the 4 readUid calls
        expect(pollProbes, 0);
      });
    });

    test('CcidCard serializes concurrent transceives (no interleaving)',
        () async {
      final platform = _SlowPlatform();
      NfcHubPlatform.instance = platform;
      addTearDown(() => NfcHubPlatform.instance = null);

      final card = CcidCard('reader-1');
      final first = card.transceive('AA');
      final second = card.transceive('BB');
      platform.release('AA');
      platform.release('BB');
      await Future.wait([first, second]);
      // BB must not have STARTED until AA completed.
      expect(platform.order, ['start:AA', 'end:AA', 'start:BB', 'end:BB']);
    });

    // Real timing, not FakeAsync: Stream.multi's done delivery does not
    // propagate through the inner subscription's onDone forwarding under
    // FakeAsync (a FakeAsync/Stream.multi interaction quirk -- verified in
    // isolation that the same forwarding completes correctly under real
    // async). The production dispose() path this guards runs in real async.
    test('dispose() completes tags() and taggedTags() for existing '
        'listeners (an await-for over tags() must end, not hang forever)',
        () async {
      final platform = _FakePlatform()
        ..readers = ['reader-1']
        ..cardsPresent.add('reader-1');
      final source = CcidSource(platform, pollInterval: const Duration(milliseconds: 10));

      var tagsDone = false;
      var taggedDone = false;
      final tagsSub =
          source.tags().listen((_) {}, onDone: () => tagsDone = true);
      final taggedSub = source
          .taggedTags()
          .listen((_) {}, onDone: () => taggedDone = true);

      // Let the poll loop run a few ticks so the card is seated/occupied.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(tagsDone, isFalse);
      expect(taggedDone, isFalse);

      await source.dispose();
      // Let the done events propagate through the Stream.multi wrappers.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(tagsDone, isTrue,
          reason: 'tags() must complete when dispose() closes the '
              'underlying controller, or an await-for over it hangs forever');
      expect(taggedDone, isTrue,
          reason: 'taggedTags() must likewise complete on dispose()');

      await tagsSub.cancel();
      await taggedSub.cancel();
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

/// A minimal [NfcHubPlatform] whose [transceive] blocks until [release] is
/// called for that exact APDU -- used to prove [CcidCard.transceive]
/// serializes concurrent calls rather than letting a second APDU start
/// before the first completes.
///
/// [release] can race ahead of [transceive] (e.g. a test calls both
/// [CcidCard.transceive]s -- which don't actually reach this platform until
/// a later microtask, since [CcidCard] chains them through a `Future.then`
/// -- and then calls [release] synchronously right after, before either
/// gate exists yet). Both [release] and [transceive] use `putIfAbsent` on
/// the same completer so whichever runs first "arms" the gate and whichever
/// runs second (create-and-await, or complete) sees the already-armed one --
/// order-independent, so a call to [release] before the matching APDU has
/// even started never gets silently dropped.
class _SlowPlatform extends NfcHubPlatform {
  final order = <String>[];
  final _gates = <String, Completer<void>>{};

  void release(String capdu) =>
      _gates.putIfAbsent(capdu, () => Completer<void>()).complete();

  @override
  Future<String?> transceive(String reader, String capdu) async {
    order.add('start:$capdu');
    final gate = _gates.putIfAbsent(capdu, () => Completer<void>());
    await gate.future;
    order.add('end:$capdu');
    return '9000';
  }
}
