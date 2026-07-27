import 'package:flutter/services.dart';
import 'package:nfc_hub/src/platform/method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connect() decodes the hex ATR string returned by the platform',
      () async {
    final channel = MethodChannelNfcHub();
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
    final channel = MethodChannelNfcHub();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.methodChannel, null);
    });

    final card = await channel.connect('fake-reader');

    expect(card.atr, isNull);
  });

  test('setLogging() forwards both flags to the native side', () async {
    final channel = MethodChannelNfcHub();
    MethodCall? seen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async {
      seen = call;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.methodChannel, null);
    });

    await channel.setLogging(enabled: true, verbose: false);

    expect(seen?.method, equals('setLogging'));
    expect(seen?.arguments, equals({'enabled': true, 'verbose': false}));
  });
}
