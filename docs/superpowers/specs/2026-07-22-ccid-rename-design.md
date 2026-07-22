# 0.8.0 rename: drop "ccid" as a project name, keep it as a protocol name

Date: 2026-07-22
Status: approved

## Problem

The package is `nfc_hub` and the repo is now `nfc-hub`, but "ccid" survives in
three unrelated places, only two of which are defects:

1. **Legitimate protocol vocabulary.** `Ccid.kt`, `CcidException`,
   `CcidRdrToPcMessage`, `CcidDescriptor`, `sendCcidPcToRdrMessage`,
   `CcidTransportBackend`, and `CcidSource` name the USB CCID device class the
   plugin actually speaks. These are correct and must not change.

2. **Misnomers in the public API.** `CcidSourceFilter` and
   `CcidConnectionState` each span *both* tag sources, so the `Ccid` prefix is
   factually wrong: `CcidSourceFilter.builtInNfc()` is a "Ccid" filter that
   selects the phone's antenna, and `CcidConnectionState.builtInNfcAvailable`
   is built-in-NFC state on a "Ccid" type. The codebase already flinched from
   this — `nfc_hub_reader.dart` defines `NfcSource` and `NfcConnectionState` as
   a wrapper and a typedef over exactly these two, so the library currently
   exports two spellings of the same concepts. `CcidCard` is fork legacy in the
   same family.

3. **Project identity.** The working directory is `ccid` and `.idea/ccid.iml`
   matches it, neither of which agrees with the package or repo name.

## Decisions

| Decision | Choice |
| --- | --- |
| Scope | Project identity + the misnamed public types. Protocol vocabulary untouched. |
| Compatibility | Clean break. No deprecated aliases. Version 0.7.0 → 0.8.0. |
| Directory move | Performed by the user after the in-repo work is committed. |
| Android namespace | Out of scope. `com.cheqplease.nfchub` contains no "ccid" and changing it is a separate breaking change. |

## Renames

| Old | New | Home |
| --- | --- | --- |
| `CcidSourceFilter` | `NfcSource` | `lib/src/nfc_hub_api.dart` |
| `CcidSourceFilter.builtInNfc()` | `NfcSource.builtIn()` | " |
| `CcidConnectionState` | `NfcConnectionState` | " |
| `CcidCard` | `ReaderCard` | `lib/src/nfc_hub_base.dart` |
| `NfcSource.toFilter()` | deleted | — |
| `typedef NfcConnectionState` | deleted | `lib/src/nfc_hub_reader.dart` |
| `.idea/ccid.iml` | `.idea/nfc_hub.iml` | + `modules.xml` reference |
| `README.md` `path: ../ccid` | `path: ../nfc_hub` | — |

Explicitly unchanged: `Ccid.kt`, `CcidDescriptor.kt`, `CcidException`,
`CcidRdrToPcMessage`, `sendCcidPcToRdrMessage`, `receiveCcidRdrToPcMessage`,
`CcidTransportBackend`, `ccid_backend.dart`, `CcidSource`, `ccid_source.dart`,
the private `_Ccid*Transport` classes, all nine `CCID_*` method-channel error
codes, and every `CCID/PC-SC` mention in the README.

## The merge direction is load-bearing

`NfcHub._tagStreams` (`nfc_hub_base.dart:34`) is keyed by the filter type and
depends on its value equality to return one shared pipeline per filter — the
guarantee documented at `nfc_hub_base.dart:70-73`.

`CcidSourceFilter` defines `==`/`hashCode` (`nfc_hub_api.dart:31-38`).
`NfcSource` defines neither.

Therefore: **keep `CcidSourceFilter`'s body, rename it to `NfcSource`, adopt
the wrapper's constructor spelling, delete the wrapper.** Merging in the other
direction produces a map key without value equality, so
`tagStream(from: NfcSource.reader('R1'))` called twice would return two
distinct streams, start two parallel pipelines, and deliver every tag twice —
silently, with no analyzer or runtime error.

Resulting type:

```dart
@immutable
class NfcSource {
  const NfcSource.builtIn()
      : _builtInNfc = true,
        _readerName = null;

  const NfcSource.reader(String name)
      : _builtInNfc = false,
        _readerName = name;

  final bool _builtInNfc;
  final String? _readerName;

  @override
  bool operator ==(Object other) =>
      other is NfcSource &&
      other._builtInNfc == _builtInNfc &&
      other._readerName == _readerName;

  @override
  int get hashCode => Object.hash(_builtInNfc, _readerName);

  @override
  String toString() => _builtInNfc
      ? 'NfcSource.builtIn()'
      : 'NfcSource.reader($_readerName)';
}
```

`NfcSource` lives in `nfc_hub_api.dart` alongside `mergeTagStreams`, which
reads its private fields. `NfcHubReader.startSession` then passes `from`
straight through to `_hub.tagStream(from: from)` with no conversion, so no
cross-file private access is introduced.

## Signature changes

- `NfcHub.tagStream({NfcSource? from})`
- `NfcHub.readTag({NfcSource? from, Duration? timeout})`
- `NfcHub.connectionState() → Stream<NfcConnectionState>`
- `NfcHub.connect(String reader) → Future<ReaderCard>`
- `NfcHub._tagStreams → Map<NfcSource?, Stream<TagDriver>>`
- `mergeTagStreams({..., NfcSource? filter})`
- `combineConnectionState(...) → Stream<NfcConnectionState>`
- `NfcHubReader.startSession({..., NfcSource? from})` — body drops `.toFilter()`
- `NfcHubPlatform.connect(String reader) → Future<ReaderCard>`
- `identifyTag(ReaderCard card)`
- `CcidTransportBackend.card → ReaderCard` (class name itself unchanged)

`lib/nfc_hub.dart` export list updates to the new names; `NfcSource` and
`NfcConnectionState` move from the `nfc_hub_reader.dart` export line to the
`nfc_hub_api.dart` line.

## Blast radius

- `ReaderCard` — 12 lib files, 8 test files
- `NfcSource` — 5 lib, 2 test
- `NfcConnectionState` — 4 lib, 2 test, 5 `example/` files (3 under
  `example/test/`, 2 under `example/lib/`)

`example/` is a real consumer and breaks on this change; it is updated in the
same commit.

## Tests

Renames are mechanical in test files. Two tests assert a concept that ceases to
exist and are **deleted, not rewritten**:

- `test/nfc_hub_reader_test.dart:96` — "NfcSource.builtIn() maps to
  CcidSourceFilter.builtInNfc()"
- `test/nfc_hub_reader_test.dart:101` — "NfcSource.reader(name) maps to
  CcidSourceFilter.reader(name)"

The test at `test/nfc_hub_api_test.dart` — "NfcHub.tagStream returns one shared
stream per filter" — is the regression guard for the equality trap above and
must stay green.

## Verification

1. `flutter analyze` — clean (the 2 pre-existing `example/test/` infos are
   unrelated and stay)
2. `flutter test` — 254 passing (256 minus the 2 deleted)
3. `flutter pub publish --dry-run` — 0 warnings
4. `grep -rn "CcidCard\|CcidSourceFilter\|CcidConnectionState" lib test example`
   returns nothing

## Release

`pubspec.yaml` → `version: 0.8.0`. CHANGELOG gains a `## 0.8.0` section with a
**Breaking** subsection naming all four removals and their replacements, plus a
line stating that CCID protocol identifiers are deliberately retained.

## Handoff

After the work is committed:

```
cd ~/StudioProjects && mv ccid nfc_hub && cd nfc_hub
```

Then reopen the project in the IDE. `example/pubspec.yaml` depends on `path: ../`,
which is relative and survives the move.
