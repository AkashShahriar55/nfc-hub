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
  Future<void> disconnect(String reader) async {}
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
  });
}
