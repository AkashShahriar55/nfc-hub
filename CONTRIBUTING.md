# Contributing to nfc_hub

Thanks for helping out. Bug reports, fixes, and support for new readers or tag
families are all welcome.

## Setup

The repository pins its Flutter version in `.fvmrc`, and CI's format check
depends on that exact version, so use [fvm](https://fvm.app):

```sh
fvm install
fvm flutter pub get
```

## Before opening a pull request

```sh
fvm dart format .
fvm dart analyze
fvm flutter test
(cd example && fvm flutter test)
```

CI runs all of these, plus `flutter pub publish --dry-run` and an example APK
build.

## Testing on hardware

Unit tests use fakes, so they cannot catch reader or antenna behavior. If your
change touches tag I/O, a transport, or the Android plugin, run the relevant
scenarios in [`docs/hardware-validation.md`](docs/hardware-validation.md) using
the `example/` app, and say in your pull request which device, reader, and tag
family you tested with.

## Pull requests

- Keep each pull request to one change.
- Add a test for every bug fix and new behavior.
- Add a `CHANGELOG.md` entry for anything users will notice, and mark breaking
  changes **Breaking**.
- Keep `Ccid` in a name only when it refers to the USB CCID protocol. Types
  that span both tag sources use `Nfc`.

## Reporting bugs

Use the bug report form, which asks for the hardware details most defects
depend on. Report security issues as described in [SECURITY.md](SECURITY.md).

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE). Participation is covered by the
[Code of Conduct](CODE_OF_CONDUCT.md).
