# nfc_hub

[![pub version](https://img.shields.io/pub/v/nfc_hub)](https://pub.dev/packages/nfc_hub)
[![pub points](https://img.shields.io/pub/points/nfc_hub)](https://pub.dev/packages/nfc_hub/score)
[![CI](https://github.com/AkashShahriar55/nfc-hub/actions/workflows/ci.yml/badge.svg)](https://github.com/AkashShahriar55/nfc-hub/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![platform: Android](https://img.shields.io/badge/platform-Android-3DDC84)

**Read NFC tags on Android through the phone's antenna and USB smart card
readers, with one API.**

Tap a tag on the phone or seat a card on a USB reader, and your app gets the
same identified, typed tag object either way.

```dart
NfcHubReader.instance.startSession(
  onDiscovered: (tag) async {
    final info = await tag.readTagInfo();
    print('Found ${info.technology}');
  },
  onError: (error) => print('Could not read tag: $error'),
);
```

## Why nfc_hub

- **Two sources, one code path.** The built-in antenna and every attached
  CCID/PC-SC reader feed a single stream.
- **Tags arrive identified.** Each tag is already typed as its family, so you
  get the right read methods without probing.
- **Each presentation is delivered once.** A seated card does not replay, and
  repeat taps on the antenna are debounced.
- **Reads never overlap.** Callbacks run one at a time, which single-threaded
  USB readers depend on.
- **Live status for your UI.** One stream reports whether NFC is on and which
  readers hold a card.
- **No manifest changes.** The plugin declares what it needs, and Android
  merges it into your app.

## Supported tags

| Family | Examples | Driver | What you can read |
| --- | --- | --- | --- |
| NFC Forum Type 2 | NTAG213/215/216, MIFARE Ultralight | `Type2Tag` | NDEF, UID, capability container, chip version |
| MIFARE Classic | Classic 1K, 4K | `MifareClassicTag` | Blocks and sectors, after key authentication |
| FeliCa | FeliCa Lite-S, transit cards | `FelicaTag` | Unencrypted blocks, system codes |
| ISO-DEP (Type 4) | DESFire, smart cards | `IsoDepTag` | SELECT, raw APDUs, DESFire version |
| ISO 14443-B | Type B cards | `TypeBTag` | ATQB, raw APDUs |

See [Limitations](#limitations) for what is not supported.

## Getting started

### Install

```yaml
dependencies:
  nfc_hub: ^0.8.0
```

### Requirements

| | |
| --- | --- |
| Platform | Android only |
| `minSdkVersion` | 24 or higher |
| Build tools | Gradle 8.7+, Java 17+ |
| Flutter | 3.24 or newer |
| USB readers | A device with USB OTG, and a CCID-compliant contactless reader |

You do not need to edit your manifest. The plugin declares the NFC permission
and marks NFC hardware as optional, so devices without NFC can still install
your app. USB access uses Android's runtime permission dialog.

### Read your first tag

```dart
import 'package:nfc_hub/nfc_hub.dart';

Future<void> scan() async {
  NfcHubReader.instance.startSession(
    onDiscovered: (tag) async {
      final info = await tag.readTagInfo();
      print('Found ${info.technology}');

      if (tag is Type2Tag) {
        for (final record in await tag.readNdef()) {
          print(record.asUri ?? record.asText);
        }
      }
    },
    onError: (error) {
      // Show a "couldn't read tag, try again" message.
    },
  );

  // Later, for example when leaving the screen:
  await NfcHubReader.instance.stopSession();
}
```

## Reading each tag family

Check a tag's type to reach its family's methods. These work the same whichever
source found the tag.

### Type 2 tags and NDEF

```dart
if (tag is Type2Tag) {
  final info = await tag.readTagInfo();
  print('Capability container: ${info.capabilityContainer}');

  for (final record in await tag.readNdef()) {
    print('${record.typeString}: ${record.asUri ?? record.asText}');
  }
}
```

`readNdef` throws if the tag holds no NDEF message.

### MIFARE Classic

Authenticate a sector before reading it.

```dart
if (tag is MifareClassicTag) {
  await tag.authenticate(
    1,
    MifareKeyType.a,
    Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
  );
  final blocks = await tag.readSector(1);
  print(blocks.first);
}
```

A rejected key throws `MifareAuthException`. To try common factory keys instead,
call `authenticateWithDefaultKeys(sector)`.

### FeliCa

```dart
if (tag is FelicaTag) {
  final result = await tag.readWithoutEncryption(0x000B, [0, 1]);
  print('Status ${result.statusFlag1}/${result.statusFlag2}');
  print(result.blocks);
}
```

### ISO-DEP

APDUs are hex strings in both directions.

```dart
if (tag is IsoDepTag) {
  final select = await tag.selectApplication('D2760000850101');
  print('SELECT response: $select');

  final response = await tag.transceive('00B0000002');
  print('READ BINARY response: $response');
}
```

For DESFire cards, `readDesfireVersion()` returns the hardware and software
version details.

### ISO 14443-B

```dart
if (tag is TypeBTag) {
  final info = await tag.readTagInfo();
  print('ATQB: ${info.atqb}');
  print(await tag.transceive('00A4040000'));
}
```

## Going further

### Listen to one source

By default, a session listens to every source. Pass `from` to narrow it.

```dart
NfcHubReader.instance.startSession(
  onDiscovered: (tag) async => print(await tag.readTagInfo()),
  onError: print,
  from: const NfcSource.builtIn(),
);

final readers = await NfcHub().listReaders();
if (readers.isNotEmpty) {
  NfcHubReader.instance.startSession(
    onDiscovered: (tag) async => print(await tag.readTagInfo()),
    onError: print,
    from: NfcSource.reader(readers.first),
  );
}
```

### Read one tag and stop

```dart
try {
  final tag = await NfcHub().readTag(timeout: const Duration(seconds: 30));
  print(await tag.readTagInfo());
} on TimeoutException {
  print('No tag presented.');
}
```

`readTag` fails on the first bad tap instead of waiting for a good one. To keep
prompting until a read succeeds, use `startSession`.

### Use streams directly

`NfcHub` is the stream API underneath `NfcHubReader`.

```dart
await for (final tag in NfcHub().tagStream()) {
  print(await tag.readTagInfo());
}
```

### Show connection status

```dart
final subscription = NfcHubReader.instance.connectionState().listen((state) {
  if (!state.builtInNfcAvailable &&
      state.builtInNfcReason == NfcUnavailableReason.disabled) {
    NfcHubReader.instance.openNfcSettings();
  }
  for (final reader in state.externalReaders) {
    print('${reader.name}: card present = ${reader.cardPresent}');
  }
});
```

`isAvailable()` gives a one-time answer without starting reader polling, so it
never triggers the USB permission dialog.

### How sessions behave

- `onDiscovered` runs once per tag presentation.
- If `onDiscovered` returns a `Future`, the next tag waits for it.
- If `onDiscovered` throws, the error goes to `onError` and the session keeps
  running.
- `onError` also receives per-tap failures, such as
  `UnrecognizedTagException` and `TagLostException`.
- If you omit `onError`, these errors are silently dropped, so always supply it.
- Starting a new session replaces the current one.

### Turn on diagnostics

Logs appear in `flutter run` and in `adb logcat` under the `flutter` tag.

```dart
await NfcHub().setLogging(enabled: true);
await NfcHub().setLogging(enabled: true, verbose: true); // Adds raw USB frames.
```

## Limitations

- **Android only.** iOS, macOS, Linux, Windows, and web are not supported.
- **Reading only.** There is no NDEF write or block write API. `transceive` on
  ISO-DEP and Type B cards sends any APDU you give it.
- **NDEF is read from Type 2 tags only.**
- **ISO 15693 (NFC-V) tags are not supported.** They surface as
  `UnrecognizedTagException`.
- **MIFARE Classic 4K sectors 32 to 39 read incorrectly with `readSector`,**
  which assumes four blocks per sector. Those sectors have 16.
- **FeliCa and Type B over USB need a PN532-based reader,** such as the ACR122U.
- **MIFARE Classic on the built-in antenna depends on the phone,** because
  Android treats it as an optional capability.

## Troubleshooting

**The USB reader never asks for permission again.** Android's prompt is
one-shot. If it was denied or dismissed, or the reader was unplugged while it
was open, unplug the reader and plug it back in.

**Built-in NFC does nothing.** Check `connectionState()`. If
`builtInNfcReason` is `disabled`, call `openNfcSettings()` so the user can turn
it on. If it is `noHardware`, the device has no NFC antenna.

**A tap reports an error instead of a tag.** The tag probably left the field or
is an unsupported family. Check the exception passed to `onError`, then turn on
[diagnostics](#turn-on-diagnostics) if it isn't clear.

## Example app

The [`example/`](example/) app is a full test harness with auto-detection, live
status for both sources, and per-family reads.

## Documentation

- [API reference](https://pub.dev/documentation/nfc_hub/latest/)
- [Migrating to 0.8](doc/migrating-to-0.8.md)
- [Changelog](CHANGELOG.md)

## Contributing

Bug reports and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup and hardware testing, and report
vulnerabilities as described in [SECURITY.md](SECURITY.md). This project follows
a [Code of Conduct](CODE_OF_CONDUCT.md).

## License

`nfc_hub` is released under the [MIT License](LICENSE).

```text
Copyright (c) 2026 Akash Shahriar
Copyright (c) 2024 nfcim
```

You can use it in commercial and closed-source apps. Keep the copyright and
license notice when you redistribute the source or binaries.

### Attribution

`nfc_hub` began as a fork of [`ccid`](https://github.com/nfcim/ccid) by nfcim,
also MIT licensed. The CCID/PC-SC transport layer derives from that work, and
its copyright notice is retained in [LICENSE](LICENSE). The built-in NFC support
and the unified tag API are new.

### Dependencies

Direct dependencies keep their own permissive licenses:

| Package | License |
| --- | --- |
| [`dart_pcsc`](https://pub.dev/packages/dart_pcsc) | BSD-3-Clause |
| [`platform_detector`](https://pub.dev/packages/platform_detector) | MIT |
| [`plugin_platform_interface`](https://pub.dev/packages/plugin_platform_interface) | BSD-3-Clause |
| [`convert`](https://pub.dev/packages/convert) | BSD-3-Clause |

Flutter's `showLicensePage` lists these automatically, which is an easy way to
include their notices in your app.

### Trademarks

MIFARE, MIFARE Classic, MIFARE Ultralight, DESFire, and NTAG are trademarks of
NXP B.V. FeliCa is a trademark of Sony Corporation. Other names belong to their
respective owners. This project is not affiliated with or endorsed by any of
them.
