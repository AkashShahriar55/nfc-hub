# Open-source release: publishing `nfc_hub` 0.8.0 to pub.dev

Date: 2026-08-03
Status: approved

## Problem

The package is production-quality but not releasable. `pub publish --dry-run`
already reports 0 warnings, so the blockers are not mechanical — they are
identity, scope, and the absence of the scaffolding a public repository needs:

1. **The public API ships under names its own design doc calls wrong.** The
   approved `2026-07-22-ccid-rename-design.md` is unimplemented. Publishing
   0.7.0 would put `CcidSourceFilter` / `CcidConnectionState` / `CcidCard` in
   front of the first users, then break them in 0.8.0.
2. **Dead platform code ships.** The plugin declares `android` as its only
   platform, yet `linux/`, `windows/`, and `darwin/` are in the published
   archive, and `example/` carries iOS/macOS/Linux/Windows runners.
3. **Package metadata is incomplete.** No `repository`, no `issue_tracker`, no
   `topics`. The README still says "Not yet published to pub.dev".
4. **The LICENSE names only the upstream author.** `Copyright (c) 2024 nfcim`
   with no line for this fork's author.
5. **No contributor-facing files.** No CONTRIBUTING, no code of conduct, no
   security policy, no issue or PR templates.
6. **CI cannot pass and does not test.** `example-app.yaml` builds a 5-platform
   × 2-variant matrix (iOS, macOS, Linux, Windows) against an Android-only
   plugin, and never runs `flutter test` — the 257-test suite is unguarded.
7. **The tree is unformatted and loses pub.dev points.** `dart format
   --set-exit-if-changed lib/` — a command the current CI already runs —
   fails on 10 of 30 files under the repo's pinned Flutter 3.38.3. A `pana`
   baseline run scores **150/160**, losing 10 points in "Pass static analysis"
   to that formatting plus info-level lints (e.g. a missing return type at
   `lib/src/platform/pcsc.dart:15`). Every other category is already full
   marks.

## Decisions

| Decision | Choice |
| --- | --- |
| Debut version | 0.8.0, with the approved rename landed first |
| Package name | `nfc_hub` (verified unclaimed on pub.dev) |
| Copyright holder | Akash Shahriar, 2026; the nfcim line is retained |
| Non-Android native dirs | Deleted, in both the plugin and the example |
| Community files | CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, issue + PR templates |
| Security reporting | GitHub private vulnerability advisories |
| First publish | Performed by the user; not automated, not done here |

## A. Land the 0.8.0 rename

Executes `2026-07-22-ccid-rename-design.md` unchanged. Restated here only as
the release's first gate:

| Old | New |
| --- | --- |
| `CcidSourceFilter` | `NfcSource` (home: `lib/src/nfc_hub_api.dart`) |
| `CcidSourceFilter.builtInNfc()` | `NfcSource.builtIn()` |
| `CcidConnectionState` | `NfcConnectionState` |
| `CcidCard` | `ReaderCard` |
| `NfcSource.toFilter()` | deleted |
| `typedef NfcConnectionState` in `nfc_hub_reader.dart` | deleted |
| `.idea/ccid.iml` | `.idea/nfc_hub.iml` (+ `modules.xml` reference) |

Protocol vocabulary is untouched: `Ccid.kt`, `CcidDescriptor.kt`,
`CcidException`, `CcidRdrToPcMessage`, `sendCcidPcToRdrMessage`,
`receiveCcidRdrToPcMessage`, `CcidTransportBackend`, `ccid_backend.dart`,
`CcidSource`, `ccid_source.dart`, the private `_Ccid*Transport` classes, all
nine `CCID_*` method-channel error codes, and every `CCID/PC-SC` mention in
prose. These name the USB device class the plugin actually speaks.

**Load-bearing constraint.** `NfcHub._tagStreams` (`nfc_hub_base.dart:35`) is a
`Map` keyed by the filter type and relies on its value equality to hand back
one shared pipeline per filter. The merged `NfcSource` must preserve `==` and
`hashCode` semantics exactly; a regression here silently duplicates tag
pipelines. A test pins this.

The directory move (`ccid` → `nfc_hub`) is the user's action, performed after
this work is committed.

## B. Prune to Android-only

Delete `linux/`, `windows/`, `darwin/` from the plugin and `example/ios`,
`example/macos`, `example/linux`, `example/windows` from the example. Both
sets are unreachable given the `android`-only platform declaration in
`pubspec.yaml`; the plugin's set additionally inflates the published archive.
`example/.flutter-plugins-dependencies` is regenerated afterward.

## C. Package metadata

**`pubspec.yaml`** — version `0.8.0`; add `repository` and `issue_tracker`
pointing at the `nfc-hub` GitHub repo; add `topics: [nfc, ccid, pcsc, rfid,
android]` (pub.dev caps topics at five, lowercase alphanumeric plus hyphen).

**`LICENSE`** — add `Copyright (c) 2026 Akash Shahriar` above the retained
`Copyright (c) 2024 nfcim` line. MIT requires the upstream notice to survive;
the README's Acknowledgements section already credits the fork.

**`README.md`** — replace the "Not yet published to pub.dev" installation block
with `nfc_hub: ^0.8.0`, demoting the git and path forms to an alternatives
subsection. Add pub-version, license, and CI badges. Add a Features section and
a supported-tag-family table so the pub.dev landing page states capability
above the fold. Fix the stale `path: ../ccid` reference to `../nfc_hub`.

**`example/README.md`** — currently unmodified Flutter boilerplate titled
`ccid_example` describing "the ccid plugin". Rewritten to describe the actual
harness: auto-detect, dual-source connection status, per-family reads.

**`example/pubspec.yaml`** — `flutter_lints` `^3.0.0` → `^5.0.0` and SDK floor
`>=3.3.3` → `>=3.5.0`, both matching the root package.

## D. Repository scaffolding

- **`CONTRIBUTING.md`** — fvm-based setup (the repo pins Flutter 3.38.3 via
  `.fvmrc`), `flutter test`, analyze/format expectations, the hardware
  validation expectation documented in `docs/hardware-validation.md`, and PR
  conventions.
- **`CODE_OF_CONDUCT.md`** — Contributor Covenant 2.1.
- **`SECURITY.md`** — GitHub private vulnerability reporting as the channel.
  Requires the user to enable it under repo Settings → Security; noted as a
  manual follow-up rather than assumed.
- **`.github/ISSUE_TEMPLATE/bug_report.yml`** — a form, not free text, with
  required fields for reader model, Android version, and tag family. Nearly
  every defect in this package is hardware-specific and unactionable without
  them.
- **`.github/ISSUE_TEMPLATE/feature_request.yml`** and **`config.yml`**.
- **`.github/pull_request_template.md`**.

## E. Formatting and lint cleanup

Prerequisite to CI being greenable, and worth 10 pub.dev points on its own.

- Run `dart format .` across the repository. Under Flutter 3.38.3's tall-style
  formatter this touches 10 files in `lib/`; the diff is mechanical and lands
  as its own commit, separate from the rename, so neither review is polluted
  by the other.
- Fix the info-level lints `pana` counts beyond `flutter_lints` (the missing
  return type at `lib/src/platform/pcsc.dart:15` and its siblings). The exact
  set is enumerated during implementation by re-running `pana` after
  formatting, since `pana` reports only the first two in its summary.
- Fix the two analyzer infos in `example/test/mrt_transaction_test.dart`
  (`depend_on_referenced_packages`, `prefer_const_declarations`).

Target: `pana` 160/160.

## F. CI

`example-app.yaml` is replaced by an Android-only workflow with two jobs:

1. **verify** — `dart pub get`, `dart format --output=none
   --set-exit-if-changed`, `dart analyze`, **`flutter test`**, and
   `flutter pub publish --dry-run`. The test run is the material addition; the
   suite is currently unguarded by CI.
2. **example** — build the example APK (debug and release), uploading both.

`publish.yml` is unchanged: tag-triggered (`v[0-9]+.[0-9]+.[0-9]+*`), OIDC via
`dart-lang/setup-dart`. It only becomes functional once automated publishing is
enabled on pub.dev, which is only possible after the package exists there.

## G. Verification and release boundary

Gates, each confirmed by running it:

- `flutter test` — 257 tests, all passing (current baseline).
- `dart analyze` — clean.
- `dart format --set-exit-if-changed` — clean (fails today; see section E).
- `flutter pub publish --dry-run` — 0 warnings (already true today).
- `pana` — 160/160, up from the 150/160 baseline measured on 2026-08-03.

**Out of scope, by design.** `flutter pub publish` is not run here. The first
publish claims the package name under the user's pub.dev account, requires
their credentials, and is irreversible — pub.dev does not permit unpublishing
after 7 days. It stays a manual user action. The same applies to enabling
automated publishing and private vulnerability reporting in repo settings;
both are documented as follow-ups.

## Non-goals

- Renaming the Android namespace `com.cheqplease.nfchub` (a separate breaking
  change, explicitly out of scope in the 0.8.0 rename design).
- Adding iOS, macOS, Linux, or Windows support.
- Deprecated aliases for the renamed types. The rename is a clean break.
- API changes beyond the approved rename.
