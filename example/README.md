# nfc_hub example

A test harness for the [`nfc_hub`](https://pub.dev/packages/nfc_hub) plugin. It
runs on Android and exercises every supported tag family against both tag
sources.

- **Auto-detect:** tap a tag on the phone or seat a card on a USB reader and it
  appears in the list, with no button press.
- **Connection status:** a live bar shows built-in NFC availability and the
  state of each attached CCID/PC-SC reader.
- **Per-family reads:** open a tag to see everything its driver can read,
  including NDEF, MIFARE sectors, FeliCa blocks, and DESFire version data.

## Run it

Connect an Android device with NFC, or a USB CCID reader through an OTG adapter,
then run:

```sh
flutter run
```

The detection code is in [`lib/harness_home.dart`](lib/harness_home.dart).
