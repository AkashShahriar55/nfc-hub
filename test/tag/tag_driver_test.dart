import 'package:nfc_hub/nfc_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UnrecognizedTagException.toString() includes the message', () {
    const exception = UnrecognizedTagException('no matching tag family');

    expect(exception.toString(), contains('no matching tag family'));
  });
}
