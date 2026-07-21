# nfc_hub

[![pub version](https://img.shields.io/pub/v/nfc_hub)](https://pub.dev/packages/nfc_hub)

A Flutter plugin for reading NFC tags through external CCID/PC-SC readers and
the device's built-in NFC antenna.

**Android only.** The package declares `android` as its only platform in
`pubspec.yaml`; it does not build or run on iOS, macOS, Linux, or Windows.

## Installation

```yaml
dependencies:
  nfc_hub: ^0.7.0
```

This plugin uses AGP 8.7, thus requires Gradle 8.7+ (which needs Java 17+ to run).

## Quickstart

The simplest way to read tags is [`NfcHubReader`](lib/src/nfc_hub_reader.dart), a
singleton facade that hides stream/subscription management:

```dart
import 'package:nfc_hub/nfc_hub.dart';

NfcHubReader.instance.startSession(
  onDiscovered: (tag) async {
    final info = await tag.readTagInfo();
    print('${info.technology} — UID ${info.uid}');
    // family-specific reads, identical whether the tag came from the
    // phone's antenna or a USB CCID reader:
    if (tag is Type2Tag) print(await tag.readNdef());
  },
  onError: (error) {
    // Per-tap failures land here too (e.g. UnrecognizedTagException,
    // TagLostException) -- the session survives them and keeps
    // delivering later taps. Use this to show a lightweight "couldn't
    // read tag, try again" message.
  },
);

// ...later, e.g. when leaving the screen:
await NfcHubReader.instance.stopSession();
```

`startSession` auto-detects tags from every source at once -- the phone's
built-in NFC antenna and any attached CCID/PC-SC reader -- so the same code
handles a tap and a seated card without branching on where it came from. Pass
`from: NfcSource.builtIn()` or `from: NfcSource.reader(name)` to restrict it
to one source.

**Delivery contract:** each tag presentation is delivered to `onDiscovered`
exactly once (no replay on resubscribe or on a `startSession` restart, and
repeat discoveries of the same tag on the built-in antenna are debounced).
`onDiscovered` calls are serialized -- if it returns a `Future`, the next
tag waits for it to complete, so reads on one tag never overlap the next.
A throwing/failing `onDiscovered` does not tear down the session.

**Error contract:** `onError`, if given, receives both connection-level
errors and per-tap failures (an unreadable or unrecognized tag, a tag that
fails identification, `TagLostException` if it leaves the field mid-read).
If `onError` is omitted, these errors are silently swallowed and the
session stays alive -- always supply it so failed taps aren't left
unexplained.

For streams, timeouts, or filtering by source directly, use the underlying
`NfcHub` API:

```dart
final hub = NfcHub();
await for (final tag in hub.tagStream()) {
  final info = await tag.readTagInfo();
  print('${info.technology} — UID ${info.uid}');
  if (tag is Type2Tag) print(await tag.readNdef());
}
```

The `example/` app is a full test harness built on this: auto-detect,
live dual-source connection status, and per-family reads for every
supported tag type.

## Troubleshooting

* **USB CCID reader: permission dialog denied or dismissed.** Android's USB
  permission prompt is a one-shot: if the user denies or ignores it, or the
  reader is unplugged while the request is pending, that reader will not
  retry on its own. Detach and re-attach the reader (or otherwise trigger a
  fresh USB attach event) to get another permission prompt.
* **Built-in NFC is off, or the device has no NFC hardware.** Check
  `NfcHubReader.instance.connectionState()` (or `NfcHub().connectionState()`),
  which reports `builtInNfcAvailable` and, when false, why
  (`NfcUnavailableReason.disabled` or `NfcUnavailableReason.noHardware`) --
  along with the live presence of every attached CCID/PC-SC reader. Call
  `NfcHubReader.instance.openNfcSettings()` to deep-link the user to the
  system NFC settings screen so they can turn it on.

## Acknowledgements

`nfc_hub` began as a fork of [`ccid`](https://github.com/nfcim/ccid) by nfcim,
MIT licensed (see `LICENSE`). The CCID/PC-SC transport layer derives from that
work; the built-in-NFC support and the unified tag API are new.
