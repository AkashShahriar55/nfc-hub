import 'package:nfc_hub/nfc_hub.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestDriver extends TagDriver {
  _TestDriver(super.card);
}

void main() {
  test('TagDriver stores the CcidCard it was constructed with', () {
    final card = CcidCard('fake-reader');

    final driver = _TestDriver(card);

    expect(driver.card, same(card));
  });

  test('UnrecognizedTagException.toString() includes the message', () {
    const exception = UnrecognizedTagException('no matching tag family');

    expect(exception.toString(), contains('no matching tag family'));
  });
}
