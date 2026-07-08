import 'package:ccid/ccid_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connect() decodes the hex ATR string returned by the platform',
      () async {
    final channel = MethodChannelCcid();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async {
      expect(call.method, equals('connect'));
      return 'AABBCC';
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.methodChannel, null);
    });

    final card = await channel.connect('fake-reader');

    expect(card.atr, equals([0xAA, 0xBB, 0xCC]));
  });

  test('connect() leaves atr null when the platform returns null', () async {
    final channel = MethodChannelCcid();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.methodChannel, null);
    });

    final card = await channel.connect('fake-reader');

    expect(card.atr, isNull);
  });
}
