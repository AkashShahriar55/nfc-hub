# nfc_hub Rename & Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `ccid` plugin to `nfc_hub` (Android package `com.cheqplease.nfchub`) and restructure `lib/` into a single public entry point over `lib/src/`, with zero behavior change.

**Architecture:** This is Plan 1 of 3 (see Roadmap below). It is a pure rename/restructure — no feature work, no protocol changes. The existing test suite is the safety net: every task must leave `flutter analyze` clean and `flutter test` fully green. Because every import line changes as a consequence of the package rename, the `lib/ccid_*.dart` flat layout is collapsed into `lib/nfc_hub.dart` (public barrel) + `lib/src/**` (implementation) in the same pass, so Plan 2 doesn't have to churn the same files twice.

**Tech Stack:** Flutter 3.38.3 / Dart SDK `>=3.5.0 <4.0.0`, Kotlin (Android plugin), Swift (darwin), C++ (linux/windows), `dart_pcsc` ^2.0.2, `flutter_test`, `flutter_lints` ^5.0.0.

## Global Constraints

Every task's requirements implicitly include this section.

- **Dart package name:** `nfc_hub`. Public entry point: `lib/nfc_hub.dart` (the only file directly under `lib/`).
- **Android package:** `com.cheqplease.nfchub`. Gradle `group` and `namespace` must both use it.
- **Android plugin class:** `NfcHubPlugin` (was `CcidPlugin`).
- **Method channel name:** `nfc_hub` (was `ccid`). The Dart string and the Kotlin string must change in the same commit or the example app breaks at runtime.
- **Example app:** Dart package `nfc_hub_example`; Android `applicationId`/`namespace` `com.cheqplease.nfchub.example`.
- **Names that intentionally do NOT change:** `CcidCard`, `Ccid.kt`/`class Ccid`, `CcidDescriptor`, `CcidException`. These name the CCID *protocol/transport* specifically, which is still exactly what they are. Plan 2 relocates them under the CCID backend; renaming them now would mean renaming twice.
- **Version:** bump to `0.4.0` (breaking change: package name + import paths + class names).
- **License:** `LICENSE` is MIT, `Copyright (c) 2024 nfcim`. Keep the file and its copyright line unchanged; add attribution to the README. Do not remove or rewrite the original copyright.
- **Behavior change budget: zero.** If a test needs its *expectations* (not its imports/identifiers) edited, stop — that means something broke.
- **Test baseline: 84 passing, 0 failing** (verified on `feature/ndef-read` at plan-writing time). Every task must end at exactly 84 passing. A drop means a file was dropped from the suite by a bad `git mv`; a rise means someone added a test, which is out of scope for this plan.
- **Platform scope:** Android is the only hardware-verified platform. darwin/linux/windows sources are renamed mechanically so they still compile and so `pub publish` is clean; they are not hardware-verified in this plan.
- Minimum Android SDK 26; AGP 8.7; Java 17.

## Roadmap (context — do not implement here)

- **Plan 1 (this document):** rename + restructure. Ships a working, renamed `nfc_hub` with today's exact behavior.
- **Plan 2:** per-technology transport interfaces + CCID transport backend; drivers stop depending on `CcidCard`. Still CCID-only, still no user-visible behavior change.
- **Plan 3:** Android built-in-NFC backend, unified `tagStream()`/`readTag()`/`connectionState()`/`openNfcSettings()`, CCID card-presence poll loop, example app rewrite.

Spec: `docs/superpowers/specs/2026-07-14-unified-nfc-transport-design.md`

## File Structure

Target layout after Task 1:

```
lib/nfc_hub.dart                        # public barrel — the only file under lib/
lib/src/nfc_hub_base.dart               # NfcHub (was Ccid) + CcidCard
lib/src/platform/platform_interface.dart # NfcHubPlatform (was CcidPlatform)
lib/src/platform/method_channel.dart     # MethodChannelNfcHub (was MethodChannelCcid)
lib/src/platform/pcsc.dart               # PcscNfcHub (was PcscCcid)
lib/src/tag/tag_driver.dart             # TagDriver, TagInfo, UnrecognizedTagException
lib/src/tag/detection.dart              # identifyTag
lib/src/tag/tag_info.dart               # CapabilityContainer, ChipVersion
lib/src/tag/type2.dart                  # Type2Tag, Type2TagInfo
lib/src/tag/mifare_classic.dart         # MifareClassicTag, MifareClassicInfo, ...
lib/src/tag/mifare_info.dart
lib/src/tag/felica.dart                 # FelicaTag, FelicaInfo, FelicaReadResult
lib/src/tag/felica_info.dart
lib/src/tag/iso_dep.dart                # IsoDepTag, IsoDepInfo
lib/src/tag/iso_b.dart                  # TypeBTag, TypeBInfo
lib/src/tag/desfire_info.dart
lib/src/ndef.dart                       # NdefRecord + TLV/record parsers
lib/src/apdu.dart                       # unchanged content
lib/src/pn532.dart                      # unchanged content
```

Tests mirror it: `test/nfc_hub_test.dart`, `test/platform/*_test.dart`, `test/tag/*_test.dart`, `test/ndef_test.dart`, `test/src/{apdu,pn532}_test.dart`.

Android sources move `android/src/main/kotlin/im/nfc/ccid/` → `android/src/main/kotlin/com/cheqplease/nfchub/`, keeping filenames `Ccid.kt` and `CcidDescriptor.kt`, renaming `CcidPlugin.kt` → `NfcHubPlugin.kt`.

---

### Task 1: Rename the Dart package and restructure `lib/`

Renames the pub package `ccid` → `nfc_hub`, moves implementation files under `lib/src/`, and updates every import in the library, the tests, and the example app. Class identifiers are **not** touched here (that's Task 3) — this task is paths and package names only, so the diff stays reviewable.

**Files:**
- Modify: `pubspec.yaml` (lines 1-4: `name`, `description`, `homepage`)
- Modify: `example/pubspec.yaml` (lines 1-2, 11: package name, description, dependency)
- Create: `lib/nfc_hub.dart` (public barrel)
- Move: all of `lib/ccid*.dart` → `lib/src/**` per the File Structure map above
- Move: all of `test/ccid_*_test.dart` → `test/**` per the map above
- Modify: `example/lib/main.dart:2`, `example/lib/tag_details_page.dart:1`, `example/test/widget_test.dart:11`, `example/test/mrt_transaction_test.dart:3-4`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the import path `package:nfc_hub/nfc_hub.dart`, which every later task and both later plans use. The public barrel must re-export exactly the same symbols `lib/ccid.dart` exports today, so no consumer loses a type.

- [ ] **Step 1: Confirm the current test suite is green (this is the safety net)**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test 2>&1 | tail -1
```

Expected: `All tests passed!` with **84** passing. If anything fails here, STOP — fix or report before renaming anything, because a red suite makes the rest of this plan unverifiable.

- [ ] **Step 2: Move the library files with `git mv` (preserves history)**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
mkdir -p lib/src/platform lib/src/tag

git mv lib/ccid_platform_interface.dart lib/src/platform/platform_interface.dart
git mv lib/ccid_method_channel.dart     lib/src/platform/method_channel.dart
git mv lib/ccid_pcsc.dart               lib/src/platform/pcsc.dart

git mv lib/ccid_tag_driver.dart     lib/src/tag/tag_driver.dart
git mv lib/ccid_tag_detection.dart  lib/src/tag/detection.dart
git mv lib/ccid_tag_info.dart       lib/src/tag/tag_info.dart
git mv lib/ccid_type2.dart          lib/src/tag/type2.dart
git mv lib/ccid_mifare_classic.dart lib/src/tag/mifare_classic.dart
git mv lib/ccid_mifare_info.dart    lib/src/tag/mifare_info.dart
git mv lib/ccid_felica.dart         lib/src/tag/felica.dart
git mv lib/ccid_felica_info.dart    lib/src/tag/felica_info.dart
git mv lib/ccid_iso_dep.dart        lib/src/tag/iso_dep.dart
git mv lib/ccid_iso_b.dart          lib/src/tag/iso_b.dart
git mv lib/ccid_desfire_info.dart   lib/src/tag/desfire_info.dart

git mv lib/ccid_ndef.dart lib/src/ndef.dart
git mv lib/ccid.dart      lib/src/nfc_hub_base.dart
```

- [ ] **Step 3: Move the test files to mirror the new layout**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
mkdir -p test/platform test/tag

git mv test/ccid_method_channel_test.dart test/platform/method_channel_test.dart

git mv test/ccid_tag_driver_test.dart    test/tag/tag_driver_test.dart
git mv test/ccid_tag_detection_test.dart test/tag/detection_test.dart
git mv test/ccid_tag_info_test.dart      test/tag/tag_info_test.dart
git mv test/ccid_type2_test.dart         test/tag/type2_test.dart
git mv test/ccid_mifare_classic_test.dart test/tag/mifare_classic_test.dart
git mv test/ccid_mifare_info_test.dart   test/tag/mifare_info_test.dart
git mv test/ccid_felica_test.dart        test/tag/felica_test.dart
git mv test/ccid_felica_info_test.dart   test/tag/felica_info_test.dart
git mv test/ccid_iso_dep_test.dart       test/tag/iso_dep_test.dart
git mv test/ccid_iso_b_test.dart         test/tag/iso_b_test.dart
git mv test/ccid_desfire_info_test.dart  test/tag/desfire_info_test.dart

git mv test/ccid_ndef_test.dart test/ndef_test.dart
git mv test/ccid_test.dart      test/nfc_hub_test.dart
```

- [ ] **Step 4: Write the public barrel `lib/nfc_hub.dart`**

This must export exactly the symbols the old `lib/ccid.dart` exported (its `export` block plus the `Ccid` and `CcidCard` classes it declared), so nothing disappears from the public API. Class names are still the old ones at this point — Task 3 renames them.

```dart
/// nfc_hub — read NFC tags through external CCID readers or (from Plan 3)
/// the device's built-in NFC antenna, behind one API.
library;

export 'src/nfc_hub_base.dart' show Ccid, CcidCard;
export 'src/ndef.dart' show NdefRecord;
export 'src/tag/detection.dart' show identifyTag;
export 'src/tag/desfire_info.dart' show DesfireVersion;
export 'src/tag/felica.dart' show FelicaInfo, FelicaTag, FelicaReadResult;
export 'src/tag/felica_info.dart' show felicaSystemCodeLabel;
export 'src/tag/iso_b.dart' show TypeBInfo, TypeBTag;
export 'src/tag/iso_dep.dart' show IsoDepInfo, IsoDepTag;
export 'src/tag/mifare_classic.dart'
    show MifareClassicInfo, MifareClassicTag, MifareKeyType, MifareAuthException;
export 'src/tag/tag_driver.dart' show TagDriver, TagInfo, UnrecognizedTagException;
export 'src/tag/tag_info.dart' show CapabilityContainer, ChipVersion;
export 'src/tag/type2.dart' show Type2Tag, Type2TagInfo;
```

- [ ] **Step 5: Strip the now-duplicated export block out of `lib/src/nfc_hub_base.dart`**

`lib/src/nfc_hub_base.dart` (the old `lib/ccid.dart`) still carries the `export` lines that now live in the barrel. Delete them — the file should keep only its `import` of the platform interface and the `Ccid` / `CcidCard` class declarations. Its head becomes:

```dart
import 'dart:typed_data';

import 'platform/platform_interface.dart';

class Ccid {
```

(everything from `class Ccid {` down stays byte-for-byte as it is today.)

- [ ] **Step 6: Rewrite every intra-library import to the new relative paths**

Each moved file's `import` lines still point at the old flat paths. Fix them:

- In `lib/src/tag/*.dart`: `import 'ccid_tag_driver.dart';` → `import 'tag_driver.dart';`, `import 'ccid_felica_info.dart';` → `import 'felica_info.dart';`, `import 'ccid_mifare_info.dart';` → `import 'mifare_info.dart';`, `import 'ccid_desfire_info.dart';` → `import 'desfire_info.dart';`, `import 'ccid_tag_info.dart';` → `import 'tag_info.dart';`, `import 'ccid_ndef.dart';` → `import '../ndef.dart';`, `import 'src/apdu.dart';` → `import '../apdu.dart';`, `import 'src/pn532.dart';` → `import '../pn532.dart';`, `import 'ccid.dart';` (and `import 'ccid.dart' show CcidCard;`) → `import '../nfc_hub_base.dart';` (preserving any `show` clause).
- In `lib/src/tag/detection.dart`: the sibling driver imports (`ccid_felica.dart`, `ccid_iso_b.dart`, `ccid_iso_dep.dart`, `ccid_mifare_classic.dart`, `ccid_type2.dart`) become `felica.dart`, `iso_b.dart`, `iso_dep.dart`, `mifare_classic.dart`, `type2.dart`.
- In `lib/src/platform/*.dart`: `import 'ccid.dart';` → `import '../nfc_hub_base.dart';`, `import 'ccid_method_channel.dart';` → `import 'method_channel.dart';`, `import 'ccid_pcsc.dart';` → `import 'pcsc.dart';`, `import 'ccid_platform_interface.dart';` → `import 'platform_interface.dart';`.
- In `lib/src/apdu.dart:5`: `import '../ccid.dart';` → `import 'nfc_hub_base.dart';`.
- In `lib/src/pn532.dart:3`: `import '../ccid.dart' show CcidCard;` → `import 'nfc_hub_base.dart' show CcidCard;`.
- In `lib/src/tag/iso_dep.dart:9`: the `export 'ccid_desfire_info.dart' show DesfireVersion;` line is now redundant with the barrel — delete it.

Let the analyzer drive this rather than guessing:

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze 2>&1 | grep -E "error|Target of URI" | head -40
```

Fix each reported unresolved URI, re-run, repeat until the only remaining errors are in `test/` and `example/` (those are Steps 7-8).

- [ ] **Step 7: Rename the package in `pubspec.yaml`**

```yaml
name: nfc_hub
description: "A Flutter plugin for reading NFC tags through external CCID/PC-SC readers and the device's built-in NFC antenna."
version: 0.4.0
homepage: https://github.com/cheqplease/nfc_hub
```

Leave the `flutter.plugin.platforms` block alone for now — Task 2 changes the Android entry, Task 4 the rest.

- [ ] **Step 8: Point the tests and the example app at `package:nfc_hub/nfc_hub.dart`**

```bash
cd /Users/akashshahriar/StudioProjects/ccid

# library + tests: package: imports and any leftover relative ones
grep -rln "package:ccid/" test example/lib example/test example/integration_test 2>/dev/null \
  | xargs sed -i '' "s|package:ccid/ccid.dart|package:nfc_hub/nfc_hub.dart|g"

# example's own package self-imports
grep -rln "package:ccid_example/" example 2>/dev/null \
  | xargs sed -i '' "s|package:ccid_example/|package:nfc_hub_example/|g"
```

Then edit `example/pubspec.yaml` by hand:

```yaml
name: nfc_hub_example
description: "Demonstrates how to use the nfc_hub plugin."
```

and change the path dependency:

```yaml
dependencies:
  nfc_hub:
    path: ../
```

Tests that reached into library internals by path (e.g. `import 'package:ccid/ccid_type2.dart';`) must now import the barrel `package:nfc_hub/nfc_hub.dart`, or — for genuinely internal symbols the barrel doesn't export, such as `parseTlvForNdefMessage`, `parseNdefRecords`, `stripAndCheckSw`, `transceiveChecked`, `transceiveEscape`, `pollTypeA`, `pollTypeB`, `mifareFamilyFromSak`, `desfireGenerationLabel`, `felicaModelName`, `MethodChannelCcid`, `CcidPlatform` — import the `src/` file directly (e.g. `import 'package:nfc_hub/src/ndef.dart';`). Importing `src/` from a package's own tests is normal and does not trip lints.

- [ ] **Step 9: Verify — analyze, test, and build the example**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter pub get
(cd example && flutter pub get)
flutter analyze
flutter test
(cd example && flutter build apk --debug)
```

Expected: `flutter analyze` reports "No issues found!"; `flutter test` passes every test that passed in Step 1, with the same count; the example APK builds. The example app will still *run* correctly because the method channel name (`ccid`) is unchanged on both sides — Task 2 changes it in lockstep.

- [ ] **Step 10: Commit**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git add -A
git commit -m "refactor!: rename package ccid -> nfc_hub and restructure lib/ under src/

BREAKING CHANGE: the package is now imported as package:nfc_hub/nfc_hub.dart.
Implementation files move under lib/src/; lib/nfc_hub.dart is the only public
entry point. Class names are unchanged in this commit."
```

---

### Task 2: Rename the Android package, plugin class, and method channel

Moves the Kotlin sources to `com.cheqplease.nfchub`, renames `CcidPlugin` → `NfcHubPlugin`, and flips the method channel string from `ccid` to `nfc_hub` on **both** sides in one commit (a split commit would leave the example app unable to talk to its plugin).

**Files:**
- Move: `android/src/main/kotlin/im/nfc/ccid/{Ccid.kt,CcidDescriptor.kt,CcidPlugin.kt}` → `android/src/main/kotlin/com/cheqplease/nfchub/{Ccid.kt,CcidDescriptor.kt,NfcHubPlugin.kt}`
- Modify: `android/build.gradle:14` (`group`), `:18` (`namespace`)
- Modify: `android/src/main/AndroidManifest.xml:2` (`package`)
- Modify: `pubspec.yaml` (the `flutter.plugin.platforms.android` block: `package`, `pluginClass`)
- Modify: `lib/src/platform/method_channel.dart:12` (channel name)
- Modify: `example/android/app/build.gradle:26` (`namespace`), `:43` (`applicationId`)
- Move: `example/android/app/src/main/kotlin/im/nfc/ccid/example/MainActivity.kt` → `.../com/cheqplease/nfchub/example/MainActivity.kt`

**Interfaces:**
- Consumes: `package:nfc_hub/nfc_hub.dart` and the `lib/src/platform/method_channel.dart` path from Task 1.
- Produces: Android plugin class `com.cheqplease.nfchub.NfcHubPlugin` and method channel name `nfc_hub`. Plan 3's Android NFC backend extends this same `NfcHubPlugin` class and adds an EventChannel named `nfc_hub/events`.

- [ ] **Step 1: Move the Kotlin sources**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
mkdir -p android/src/main/kotlin/com/cheqplease/nfchub

git mv android/src/main/kotlin/im/nfc/ccid/Ccid.kt           android/src/main/kotlin/com/cheqplease/nfchub/Ccid.kt
git mv android/src/main/kotlin/im/nfc/ccid/CcidDescriptor.kt android/src/main/kotlin/com/cheqplease/nfchub/CcidDescriptor.kt
git mv android/src/main/kotlin/im/nfc/ccid/CcidPlugin.kt     android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt

rmdir -p android/src/main/kotlin/im/nfc/ccid 2>/dev/null || true
```

- [ ] **Step 2: Update the Kotlin package declarations and the plugin class name**

In all three files, line 1 becomes:

```kotlin
package com.cheqplease.nfchub
```

In `NfcHubPlugin.kt`, rename the class and its KDoc (line 20-21):

```kotlin
/** NfcHubPlugin */
class NfcHubPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
```

and change the channel name (line 73) and the USB permission action (line 296) — the action string is a broadcast intent action and must be unique to this package:

```kotlin
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "nfc_hub")
```

```kotlin
        private const val ACTION_USB_PERMISSION = "com.cheqplease.nfchub.USB_PERMISSION"
```

Leave `class Ccid`, `CcidDescriptor`, `CcidException`, and the `TAG` constant as they are (see Global Constraints).

- [ ] **Step 3: Update gradle and the plugin manifest**

`android/build.gradle` line 14:

```groovy
group 'com.cheqplease.nfchub'
```

line 18:

```groovy
        namespace 'com.cheqplease.nfchub'
```

`android/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.cheqplease.nfchub">
</manifest>
```

- [ ] **Step 4: Update the pubspec plugin declaration**

In `pubspec.yaml`, the Android entry only:

```yaml
flutter:
  plugin:
    platforms:
      android:
        package: com.cheqplease.nfchub
        pluginClass: NfcHubPlugin
```

(The ios/macos/linux/windows entries still say `CcidPlugin` — Task 4 fixes those.)

- [ ] **Step 5: Flip the Dart-side channel name**

`lib/src/platform/method_channel.dart` line 12:

```dart
  final methodChannel = const MethodChannel('nfc_hub');
```

- [ ] **Step 6: Update the example app's Android identity**

`example/android/app/build.gradle` line 26 and 43:

```groovy
    namespace "com.cheqplease.nfchub.example"
```

```groovy
        applicationId "com.cheqplease.nfchub.example"
```

Move `MainActivity.kt` and update its `package` line:

```bash
cd /Users/akashshahriar/StudioProjects/ccid/example/android/app/src/main
mkdir -p kotlin/com/cheqplease/nfchub/example
git mv kotlin/im/nfc/ccid/example/MainActivity.kt \
       kotlin/com/cheqplease/nfchub/example/MainActivity.kt
rmdir -p kotlin/im/nfc/ccid/example 2>/dev/null || true
```

Then set its first line to:

```kotlin
package com.cheqplease.nfchub.example
```

- [ ] **Step 7: Fix the channel-name expectation in the platform test**

`test/platform/method_channel_test.dart` sets up a mock handler against the channel. Its `MethodChannel('ccid')` reference (if it constructs one directly) must become `MethodChannel('nfc_hub')`. Find it:

```bash
cd /Users/akashshahriar/StudioProjects/ccid
grep -n "'ccid'" test/platform/method_channel_test.dart
```

Change any hit to `'nfc_hub'`. This is an identifier/wiring change, not an expectation change, so it is within the zero-behavior-change budget.

- [ ] **Step 8: Verify — analyze, test, and run the example on a device**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test
(cd example && flutter build apk --debug)
```

Expected: analyze clean, all tests pass, APK builds.

**Hardware gate (must not be skipped):** install the example on an Android device with the ACR122U attached, tap "List readers", connect, and read a tag. Expected: the reader is listed and a tag reads exactly as before the rename. This is the only check that proves the renamed method channel is wired end to end — a passing unit suite cannot catch a channel-name mismatch.

```bash
(cd example && flutter run)
```

- [ ] **Step 9: Commit**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git add -A
git commit -m "refactor!: rename Android package to com.cheqplease.nfchub, channel to nfc_hub

BREAKING CHANGE: Android plugin class is now
com.cheqplease.nfchub.NfcHubPlugin and the method channel is named nfc_hub.
The USB permission broadcast action is now com.cheqplease.nfchub.USB_PERMISSION."
```

---

### Task 3: Rename the Dart public classes

`Ccid` → `NfcHub`, and the platform-interface trio. Pure identifier rename; no logic moves.

**Files:**
- Modify: `lib/src/nfc_hub_base.dart` (`class Ccid` → `class NfcHub`)
- Modify: `lib/src/platform/platform_interface.dart` (`CcidPlatform` → `NfcHubPlatform`)
- Modify: `lib/src/platform/method_channel.dart` (`MethodChannelCcid` → `MethodChannelNfcHub`)
- Modify: `lib/src/platform/pcsc.dart` (`PcscCcid` → `PcscNfcHub`)
- Modify: `lib/nfc_hub.dart` (barrel `show` clause)
- Modify: `test/nfc_hub_test.dart`, `test/platform/method_channel_test.dart`, `test/tag/*_test.dart` (any that construct these)
- Modify: `example/lib/main.dart`, `example/lib/tag_details_page.dart`

**Interfaces:**
- Consumes: the file layout from Task 1.
- Produces: `NfcHub` (the class app code instantiates), `NfcHubPlatform` (the platform-interface base Plan 3 extends with `tagStream`/`connectionState`/`openNfcSettings`), `MethodChannelNfcHub`, `PcscNfcHub`. `CcidCard` keeps its name.

- [ ] **Step 1: Rename the identifiers across lib, test, and example**

These four names are unambiguous (no substring collisions with `CcidCard`, `CcidException`, `CcidDescriptor`, or the Kotlin `Ccid`), so a word-boundary substitution is safe. Order matters: do the longer names before the bare `Ccid`.

**macOS `sed` caveat — this bites silently.** BSD `sed` (the default on macOS) does not support GNU's `\b` word-boundary escape. A `s/\bCcid\b/NfcHub/g` matches *nothing*, changes *nothing*, and exits *successfully* — you get a clean run and an unrenamed tree. Use BSD's `[[:<:]]` / `[[:>:]]` word-boundary classes instead:

```bash
cd /Users/akashshahriar/StudioProjects/ccid
FILES=$(grep -rl "CcidPlatform\|MethodChannelCcid\|PcscCcid\|Ccid" lib test example/lib example/test 2>/dev/null)
echo "$FILES"

for f in $FILES; do
  sed -i '' \
    -e 's/[[:<:]]CcidPlatform[[:>:]]/NfcHubPlatform/g' \
    -e 's/[[:<:]]MethodChannelCcid[[:>:]]/MethodChannelNfcHub/g' \
    -e 's/[[:<:]]PcscCcid[[:>:]]/PcscNfcHub/g' \
    -e 's/[[:<:]]Ccid[[:>:]]/NfcHub/g' \
    "$f"
done
```

`[[:<:]]Ccid[[:>:]]` matches only the standalone word `Ccid`, so `CcidCard`, `CcidException`, and `CcidDescriptor` are untouched. Do not take that on faith — the whole task hinges on it. Verify both directions before moving on:

```bash
grep -rn "\bCcidCard\b" lib | head -3        # expect: still present, unrenamed
grep -rnw "Ccid" lib test example/lib     # expect: no output
```

- [ ] **Step 2: Fix the doc comments the rename left stale**

`sed` renames identifiers but not prose. Two known spots:

`lib/src/platform/platform_interface.dart` — the `instance` getter's doc comment says "Defaults to [MethodChannelCcid] on mobile/macOS, [PcscCcid] elsewhere." It now reads `[MethodChannelNfcHub]` / `[PcscNfcHub]` (the sed already fixed the bracketed refs, since those are word-boundary matches). Confirm it reads correctly.

`lib/src/platform/platform_interface.dart:47` — `listReaders()` throws `UnimplementedError('poll() has not been implemented.')`, naming a method that doesn't exist. Fix the stale message while you're here:

```dart
  Future<List<String>> listReaders() {
    throw UnimplementedError('listReaders() has not been implemented.');
  }
```

- [ ] **Step 3: Update the barrel's `show` clause**

`lib/nfc_hub.dart` line 5 (the sed will have already rewritten it; confirm):

```dart
export 'src/nfc_hub_base.dart' show NfcHub, CcidCard;
```

- [ ] **Step 4: Verify**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test
(cd example && flutter build apk --debug)
```

Expected: analyze clean, all tests pass with the same count as Task 1 Step 1, APK builds.

- [ ] **Step 5: Commit**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git add -A
git commit -m "refactor!: rename Ccid -> NfcHub and the platform-interface classes

BREAKING CHANGE: Ccid is now NfcHub; CcidPlatform/MethodChannelCcid/PcscCcid are
now NfcHubPlatform/MethodChannelNfcHub/PcscNfcHub. CcidCard keeps its name -- it
names the CCID transport specifically."
```

---

### Task 4: Rename the darwin/linux/windows scaffolding

Mechanical, so the non-Android platform entries in `pubspec.yaml` still resolve and `pub publish` is clean. Per Global Constraints these are not hardware-verified.

**Files:**
- Move/modify: `darwin/ccid.podspec` → `darwin/nfc_hub.podspec`; `darwin/ccid/` → `darwin/nfc_hub/`; `darwin/ccid/Sources/ccid/CcidPlugin.swift` → `darwin/nfc_hub/Sources/nfc_hub/NfcHubPlugin.swift`; `darwin/ccid/Package.swift`
- Move/modify: `linux/ccid_plugin.cc` → `linux/nfc_hub_plugin.cc`; `linux/include/ccid/ccid_plugin.h` → `linux/include/nfc_hub/nfc_hub_plugin.h`; `linux/CMakeLists.txt`
- Move/modify: `windows/ccid_plugin_c_api.cpp` → `windows/nfc_hub_plugin_c_api.cpp`; `windows/include/ccid/ccid_plugin_c_api.h` → `windows/include/nfc_hub/nfc_hub_plugin_c_api.h`; `windows/CMakeLists.txt`
- Modify: `pubspec.yaml` (ios/macos/linux/windows `pluginClass` entries)

**Interfaces:**
- Consumes: nothing from Tasks 1-3 beyond the package name.
- Produces: nothing later tasks depend on. This task exists so the repo is internally consistent, not to enable a feature.

- [ ] **Step 1: Move the darwin sources**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git mv darwin/ccid.podspec darwin/nfc_hub.podspec
git mv darwin/ccid darwin/nfc_hub
git mv darwin/nfc_hub/Sources/ccid darwin/nfc_hub/Sources/nfc_hub
git mv darwin/nfc_hub/Sources/nfc_hub/CcidPlugin.swift darwin/nfc_hub/Sources/nfc_hub/NfcHubPlugin.swift
```

Then edit:

- `darwin/nfc_hub.podspec` line 6: `s.name = 'nfc_hub'`; line 16: `s.source_files = 'nfc_hub/Sources/nfc_hub/**/*.swift'`.
- `darwin/nfc_hub/Package.swift` lines 7, 13, 18: the package name, the `.library(name:targets:)`, and the target name all currently say `ccid` → `nfc_hub`.
- `darwin/nfc_hub/Sources/nfc_hub/NfcHubPlugin.swift`: rename `public class CcidPlugin` → `public class NfcHubPlugin`; line 40's channel name `FlutterMethodChannel(name: "ccid", ...)` → `name: "nfc_hub"`.

- [ ] **Step 2: Move the linux sources**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git mv linux/ccid_plugin.cc linux/nfc_hub_plugin.cc
git mv linux/include/ccid linux/include/nfc_hub
git mv linux/include/nfc_hub/ccid_plugin.h linux/include/nfc_hub/nfc_hub_plugin.h
```

In `linux/CMakeLists.txt`: `set(PROJECT_NAME "nfc_hub")`, `set(PLUGIN_NAME "nfc_hub_plugin")`, and update the `add_library` source path to `nfc_hub_plugin.cc`. In `linux/nfc_hub_plugin.cc` and its header: update the `#include` of the renamed header, the `ccid_plugin` symbol prefixes, and the `"ccid"` channel string → `"nfc_hub"`.

- [ ] **Step 3: Move the windows sources**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git mv windows/ccid_plugin_c_api.cpp windows/nfc_hub_plugin_c_api.cpp
git mv windows/include/ccid windows/include/nfc_hub
git mv windows/include/nfc_hub/ccid_plugin_c_api.h windows/include/nfc_hub/nfc_hub_plugin_c_api.h
```

In `windows/CMakeLists.txt`: `set(PROJECT_NAME "nfc_hub")`, `set(PLUGIN_NAME "nfc_hub_plugin")`, update the source path. In the `.cpp`/`.h`: update the include, the `CcidPluginCApi` symbol → `NfcHubPluginCApi`, and the channel string.

- [ ] **Step 4: Update the remaining pubspec plugin entries**

```yaml
      ios:
        pluginClass: NfcHubPlugin
        sharedDarwinSource: true
      macos:
        pluginClass: NfcHubPlugin
        sharedDarwinSource: true
      linux:
        pluginClass: NfcHubPlugin
      windows:
        pluginClass: NfcHubPluginCApi
```

- [ ] **Step 5: Verify no `ccid` identifiers survive outside the intentional keeps**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
grep -rni "ccid" --include="*.dart" --include="*.kt" --include="*.swift" --include="*.cc" --include="*.cpp" --include="*.h" --include="*.gradle" --include="*.yaml" --include="*.podspec" --include="CMakeLists.txt" \
  lib test android darwin linux windows example pubspec.yaml
```

Expected hits, and *only* these: `CcidCard`, `Ccid.kt`'s `class Ccid` / `CcidDescriptor` / `CcidException` / `Protocol` / `LevelOfExchange`, the CCID-protocol comments and constants (`MESSAGE_TYPE_PC_TO_RDR_*`, `USB_CLASS_CSCID`), and the word "CCID" in prose/docs. Any *file path* or *channel string* or *package name* still containing `ccid` is a miss — fix it.

```bash
flutter analyze
flutter test
(cd example && flutter build apk --debug)
```

- [ ] **Step 6: Commit**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git add -A
git commit -m "refactor: rename darwin/linux/windows plugin scaffolding to nfc_hub

Mechanical rename so the non-Android pubspec platform entries resolve.
Not hardware-verified -- Android is the supported platform."
```

---

### Task 5: Docs, attribution, changelog, and publish dry-run

**Files:**
- Modify: `README.md` (title, install snippet, usage samples, attribution)
- Modify: `CHANGELOG.md` (0.4.0 entry)
- Verify: `LICENSE` (unchanged — see Global Constraints)

**Interfaces:**
- Consumes: the final public API from Task 3 (`NfcHub`, `CcidCard`, `identifyTag`, the drivers).
- Produces: nothing code-level. Gate for `pub publish`.

- [ ] **Step 1: Update the README**

Retitle to `# nfc_hub`, update the pub badge/links to the `nfc_hub` package, change the install snippet to `nfc_hub: ^0.4.0`, and rewrite the usage sample to the new names:

```dart
import 'package:nfc_hub/nfc_hub.dart';

final nfcHub = NfcHub();
final readers = await nfcHub.listReaders();
final card = await nfcHub.connect(readers.first);
final tag = await identifyTag(card);
final info = await tag.readTagInfo();
print(info.technology);
```

Keep the existing Android/Linux/Windows/macOS install prerequisites sections as they are — they're still accurate.

Add an attribution section near the bottom (the LICENSE requires the copyright notice be preserved; this makes the provenance legible):

```markdown
## Acknowledgements

`nfc_hub` began as a fork of [`ccid`](https://github.com/nfcim/ccid) by nfcim,
MIT licensed (see `LICENSE`). The CCID/PC-SC transport layer derives from that
work; the built-in-NFC support and the unified tag API are new.
```

- [ ] **Step 2: Add the changelog entry**

Prepend to `CHANGELOG.md`:

```markdown
## 0.4.0

**Breaking:** the package is renamed from `ccid` to `nfc_hub`.

- Import path is now `package:nfc_hub/nfc_hub.dart`; `lib/` is restructured
  behind a single public entry point.
- `Ccid` is now `NfcHub`. `CcidPlatform`, `MethodChannelCcid`, and `PcscCcid`
  are now `NfcHubPlatform`, `MethodChannelNfcHub`, and `PcscNfcHub`.
  `CcidCard` keeps its name.
- The Android package is now `com.cheqplease.nfchub` and the plugin class is
  `NfcHubPlugin`. The method channel is named `nfc_hub`; the USB permission
  broadcast action is `com.cheqplease.nfchub.USB_PERMISSION`.
- No functional changes: tag reading behaves exactly as in 0.3.0.
```

- [ ] **Step 3: Confirm the LICENSE is untouched**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git diff HEAD~4 --stat -- LICENSE
```

Expected: no output (the file was never modified). If it shows changes, revert them — the MIT terms require the original copyright notice be retained.

- [ ] **Step 4: Verify with a publish dry-run**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test
flutter pub publish --dry-run
```

Expected: `flutter pub publish --dry-run` reports "Package has 0 warnings." Common failures to fix if it complains: `homepage` unreachable, missing `CHANGELOG.md` entry matching `version:`, or files in `lib/` other than the entry point (there should be exactly one: `nfc_hub.dart`).

- [ ] **Step 5: Commit**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
git add -A
git commit -m "docs: update README/CHANGELOG for the nfc_hub rename, add attribution"
```

---

## Definition of Done

- `flutter analyze` → "No issues found!"
- `flutter test` → **84 passing, 0 failing** (the pre-rename baseline).
- `flutter pub publish --dry-run` → 0 warnings.
- Example app builds **and** reads a real tag through an ACR122U on a physical Android device (Task 2's hardware gate).
- `grep -rni ccid` across the repo returns only: `CcidCard`, the Kotlin CCID-protocol classes, CCID-protocol constants/comments, and the word "CCID" in prose.
- `LICENSE` is byte-identical to its state at the start of the plan.
