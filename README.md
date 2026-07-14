# nfc_hub

[![pub version](https://img.shields.io/pub/v/nfc_hub)](https://pub.dev/packages/nfc_hub)
[![Build Example App](https://github.com/nfcim/ccid/actions/workflows/example-app.yaml/badge.svg)](https://github.com/nfcim/ccid/actions/workflows/example-app.yaml)

A Flutter plugin for reading NFC tags through external CCID/PC-SC readers and the device's built-in NFC antenna.

## Installation

```yaml
dependencies:
  nfc_hub: ^0.4.0
```

```dart
import 'package:nfc_hub/nfc_hub.dart';

final nfcHub = NfcHub();
final readers = await nfcHub.listReaders();
final card = await nfcHub.connect(readers.first);

final driver = await identifyTag(card);
final info = await driver.readTagInfo();
print(info.technology);
```

### Android

This plugin uses AGP 8.7, thus requires Gradle 8.7+ (which needs Java 17+ to run).

### Linux / Windows

This plugin uses [`dart_pcsc`](https://pub.dev/packages/dart_pcsc), thus has a runtime dependency on [`PCSCLite`](https://pcsclite.apdu.fr/) to provide PC/SC APIs on Linux:

* Debian / Ubuntu: `sudo apt-get install pcscd libpcsclite1`
* RHEL / Fedora: `sudo dnf install pcsc-lite`

Should you encounter any permission problem, please check [README.polkit](https://github.com/LudovicRousseau/PCSC/blob/master/doc/README.polkit) from PCSCLite.

### macOS / iOS

This plugin uses [CryptoTokenKit](https://developer.apple.com/documentation/cryptotokenkit) on macOS, 
which is available since macOS 10.10 / iOS 13.0.

The `com.apple.security.smartcard` entitlement is required.

## Acknowledgements

`nfc_hub` began as a fork of [`ccid`](https://github.com/nfcim/ccid) by nfcim,
MIT licensed (see `LICENSE`). The CCID/PC-SC transport layer derives from that
work; the built-in-NFC support and the unified tag API are new.
