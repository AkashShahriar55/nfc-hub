import 'dart:typed_data';

import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:ccid/src/apdu.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    return responses[capdu];
  }

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  tearDown(() {
    CcidPlatform.instance = null;
  });

  group('stripAndCheckSw', () {
    test('strips a trailing 9000 status word', () {
      final result = stripAndCheckSw('${hex.encode([0xAA, 0xBB])}9000');
      expect(result, equals([0xAA, 0xBB]));
    });

    test('returns null for a non-9000 status word', () {
      expect(stripAndCheckSw('${hex.encode([0xAA])}6A82'), isNull);
    });

    test('returns null for a null response', () {
      expect(stripAndCheckSw(null), isNull);
    });

    test('returns null for a response shorter than the status word', () {
      expect(stripAndCheckSw('90'), isNull);
    });
  });

  group('transceiveChecked', () {
    test('returns the data bytes on a 9000 response', () async {
      CcidPlatform.instance =
          _FakeCcidPlatform({'00A4': '${hex.encode([0x01, 0x02])}9000'});
      final card = CcidCard('fake-reader');

      final data = await transceiveChecked(card, '00A4');

      expect(data, equals([0x01, 0x02]));
    });

    test('throws when the response has a non-9000 status word', () async {
      CcidPlatform.instance =
          _FakeCcidPlatform({'00A4': '${hex.encode([0x01])}6A82'});
      final card = CcidCard('fake-reader');

      expect(() => transceiveChecked(card, '00A4'), throwsException);
    });
  });

  group('transceiveEscape', () {
    test('wraps the payload in the FF 00 00 00 <Lc> escape command and '
        'returns the checked response', () async {
      CcidPlatform.instance = _FakeCcidPlatform(
          {'FF00000003AABBCC': '${hex.encode([0x01, 0x02])}9000'});
      final card = CcidCard('fake-reader');

      final data = await transceiveEscape(
          card, Uint8List.fromList([0xAA, 0xBB, 0xCC]));

      expect(data, equals([0x01, 0x02]));
    });
  });
}
