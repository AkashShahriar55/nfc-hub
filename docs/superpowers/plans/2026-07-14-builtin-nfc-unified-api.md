# Built-in Android NFC + Unified Tag API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second tag source — the device's built-in NFC antenna — behind the same transport interfaces the CCID reader already uses, and unify both behind one API (`tagStream()` / `readTag()` / `connectionState()`), so an app never has to know which source produced a tag.

**Architecture:** Plan 3 of 4. Plan 2 decoupled the five drivers onto typed transports; this plan supplies a second implementation of those transports (Android `android.nfc.tech.*`) and a source-merging layer above them. The drivers are **not touched**. `identifyTag` gains a second entry point (Android knows its tag's technology from `Tag.getTechList()` and needs no probing). A CCID poll loop provides card auto-detect so both sources are event-driven.

**Tech Stack:** Flutter 3.38.3 / Dart SDK `>=3.5.0 <4.0.0`, Kotlin (Android `NfcAdapter` reader mode, `android.nfc.tech.*`), `flutter_test`. No new dependencies.

## Global Constraints

Every task's requirements implicitly include this section.

- **Do not touch the five drivers** (`lib/src/tag/{type2,mifare_classic,felica,iso_dep,iso_b}.dart`). If a driver needs changing to make Android work, the transport abstraction has failed and you must STOP and report — that is a design bug, not an implementation detail.
- **Do not change any CCID pseudo-APDU byte, offset, `Lc`, or endianness.** They are hardware-validated against a real ACR122U with real MIFARE Classic, FeliCa (Dhaka MRT), and NTAG cards. This repo has already shipped one malformed-APDU bug (`FFB00000<page>10`).
- **Test baseline: 116 passing, 0 failing.** May go UP, never down.
- `flutter analyze` clean (2 pre-existing info-lints in `example/test/mrt_transaction_test.dart` are expected).
- `flutter pub publish --dry-run` → "Package has 0 warnings.", archive well under 1 MB. Do not break `.pubignore` (pub uses it *instead of* `.gitignore`; without restating `build/` the archive balloons to 15 MB).
- **Android package is `com.cheqplease.nfchub`; plugin class `NfcHubPlugin`; method channel `nfc_hub`.** The new event channel is `nfc_hub/events`.
- Minimum Android SDK 26; AGP 8.7; Java 17. Kotlin sources live in `android/src/main/kotlin/com/cheqplease/nfchub/`.
- **Tag sessions are LAZY-CONNECT, HELD.** See "Tag session model" below. This is load-bearing for the whole plan.
- Every task must leave a GREEN build.

Spec: `docs/superpowers/specs/2026-07-14-unified-nfc-transport-design.md`.

## Roadmap

- **Plan 1 (done):** rename to `nfc_hub`.
- **Plan 2 (done, v0.5.0):** transport interfaces + CCID backend. Drivers are transport-agnostic.
- **Plan 3 (this document):** Android built-in-NFC backend + unified `tagStream()`/`readTag()`/`connectionState()`/`openNfcSettings()` + CCID card-presence poll loop.
- **Plan 4 (next):** rebuild the example app as a real test harness demonstrating both sources.

---

## Tag session model (read before Task 1)

Android differs from CCID in three ways that drive every design decision here:

1. **A `Tag` object dies when the tag leaves the RF field.** Any call after that throws Android's `TagLostException`.
2. **Only ONE tech may be connected to a `Tag` at a time.** You cannot hold `NfcA` and `MifareClassic` open simultaneously.
3. **Identity fields are free.** `Tag.getId()`, `NfcA.getAtqa()`, `NfcA.getSak()`, `NfcF.getManufacturer()`, `IsoDep.getHistoricalBytes()` all read from the `Tag`'s bundled extras and require **no `connect()`**.

Therefore:

- On discovery, the Kotlin side reads all identity fields **without connecting** and ships them to Dart in the discovery event.
- It picks ONE tech (from `getTechList()`), and `connect()`s it **lazily, on the first actual read**.
- It **holds** that connection until the tag leaves the field or reader mode stops. This mirrors how CCID holds a card session, so `TagDriver` methods (`readNdef`, `readSector`, `readWithoutEncryption`) work **identically on both sources**. That parity is the entire point of the plan.
- A read after the tag is gone surfaces as our `TagLostException` — the same class of failure as pulling a card off the reader.

## File Structure

New Kotlin:
```
android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderMode.kt   # NfcAdapter reader mode, tag handles, tech dispatch
```
Modified Kotlin: `NfcHubPlugin.kt` (adds the NFC methods + EventChannel; keeps all existing CCID/USB code untouched).

New Dart:
```
lib/src/transport/tag_backend.dart       # TagBackend interface + TagTechHint + buildDriver() factory
lib/src/transport/android_backend.dart   # AndroidNfcBackend: the 5 transports over the method channel
lib/src/source/tag_source.dart           # TagSource descriptor + NfcHubSourceFilter
lib/src/source/android_source.dart       # reader-mode events -> Stream<TagDriver>
lib/src/source/ccid_source.dart          # poll loop -> Stream<TagDriver>
lib/src/source/connection_state.dart     # NfcHubConnectionState, ExternalReaderState, NfcUnavailableReason
```
Modified Dart: `lib/src/transport/ccid_backend.dart` (implement `TagBackend`), `lib/src/tag/detection.dart` (share the driver factory), `lib/src/nfc_hub_base.dart` (the new `NfcHub` API), `lib/nfc_hub.dart` (barrel).

---

### Task 1: `TagBackend` abstraction + shared driver factory

Right now `identifyTag(CcidCard)` constructs `CcidTransportBackend` directly. Android needs to produce the same five drivers from a different backend. Extract the seam.

**Files:**
- Create: `lib/src/transport/tag_backend.dart`
- Modify: `lib/src/transport/ccid_backend.dart` (declare `implements TagBackend`)
- Modify: `lib/src/tag/detection.dart` (use the shared factory)
- Create: `test/transport/tag_backend_test.dart`

**Interfaces:**
- Produces:
```dart
/// A source of typed transports for one tag. Implemented by
/// CcidTransportBackend (a card on a reader) and AndroidNfcBackend (a tag
/// on the device's antenna).
abstract class TagBackend {
  /// The card's ATR, where the source has one. Null on built-in NFC — the
  /// antenna has no ATR concept.
  Uint8List? get atr;

  Type2Transport type2();
  NfcFTransport nfcF();
  Future<MifareClassicTransport> mifareClassic();
  Future<IsoDepTransport> isoDep();
  Future<NfcBTransport?> nfcB();
}

/// A tag family, when the source can name it outright.
enum TagTechHint { type2, mifareClassic, felica, isoDep, typeB }

/// Builds the driver for [hint] from [backend]. The ONE place drivers are
/// constructed, shared by both sources.
Future<TagDriver> buildDriver(TagBackend backend, TagTechHint hint) async {
  switch (hint) {
    case TagTechHint.type2:
      return Type2Tag(backend.type2(), atr: backend.atr);
    case TagTechHint.mifareClassic:
      return MifareClassicTag(await backend.mifareClassic(), atr: backend.atr);
    case TagTechHint.felica:
      return FelicaTag(backend.nfcF(), atr: backend.atr);
    case TagTechHint.isoDep:
      return IsoDepTag(await backend.isoDep());
    case TagTechHint.typeB:
      final b = await backend.nfcB();
      if (b == null) throw const TagLostException('No Type B target');
      return TypeBTag(b, atr: backend.atr);
  }
}
```
  Note `IsoDepTag` takes NO `atr:` — it sources it from `transport.historicalBytes` (see Plan 2). Do not add one.

- [ ] **Step 1: Write the failing test**

```dart
// test/transport/tag_backend_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/tag_backend.dart';

void main() {
  test('buildDriver returns the driver matching each hint', () async {
    final backend = _FakeBackend();

    expect(await buildDriver(backend, TagTechHint.type2), isA<Type2Tag>());
    expect(await buildDriver(backend, TagTechHint.mifareClassic),
        isA<MifareClassicTag>());
    expect(await buildDriver(backend, TagTechHint.felica), isA<FelicaTag>());
    expect(await buildDriver(backend, TagTechHint.isoDep), isA<IsoDepTag>());
    expect(await buildDriver(backend, TagTechHint.typeB), isA<TypeBTag>());
  });

  test('buildDriver threads the backend ATR into the driver', () async {
    final atr = Uint8List.fromList([0x3B, 0x8F]);
    final backend = _FakeBackend(atr: atr);

    final info = await (await buildDriver(backend, TagTechHint.type2))
        .readTagInfo();

    expect(info.atr, atr);
  });
}
```
(Write `_FakeBackend` implementing `TagBackend` with fake transports. Reuse the fake-transport doubles already in `test/tag/*_test.dart` — read one for the idiom.)

- [ ] **Step 2: Run it, confirm it fails** (`tag_backend.dart` doesn't exist).

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test test/transport/tag_backend_test.dart
```

- [ ] **Step 3: Write `lib/src/transport/tag_backend.dart`** with the code above.

- [ ] **Step 4: Make `CcidTransportBackend implements TagBackend`.**
It already has all five factory methods and a `card`. Add `Uint8List? get atr => card.atr;`. Nothing else changes.

- [ ] **Step 5: Rewire `detection.dart` to use `buildDriver`.**
Replace each `return Type2Tag(backend.type2(), atr: atr);` with `return buildDriver(backend, TagTechHint.type2);` and so on for all five, in BOTH `_identifyFromAtr` and `_identifyByProbing`.

**DO NOT touch:** the ATR-matching logic (the PC/SC RID `A0 00 00 03 06` discrimination, the `standard == 0x03` check, the C0/C1 card-name bytes), the probe ORDER (Get UID → Read CC → SELECT → MIFARE → FeliCa → Type B), or any `log.add(...)` message. That function was corrected twice against real hardware and a test asserts on its exception message.

Also preserve the Plan 2 fix: `mifareClassic()` never throws now, and the ATR's MIFARE branch returns `MifareClassicTag` **outright** (no fall-through to probing — that fall-through caused a silent misidentification as ISO-DEP).

- [ ] **Step 5b: Run the tests to verify they pass**

```bash
flutter test test/transport/tag_backend_test.dart
flutter test test/tag/detection_test.dart   # MUST pass with zero assertion edits
flutter test 2>&1 | tail -1                 # >= 116
flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: extract TagBackend + shared buildDriver factory

identifyTag constructed CcidTransportBackend directly. Android needs to produce
the same five drivers from a different backend, so the seam is now explicit."
```

---

### Task 2: Kotlin — reader mode, tag handles, discovery events

Adds NFC to the Android plugin. **All existing USB/CCID code stays untouched.**

**Files:**
- Create: `android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderMode.kt`
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt`
- Modify: `android/src/main/AndroidManifest.xml`

**Interfaces:**
- Produces (method channel `nfc_hub`):
  - `nfcStart()` → enables reader mode. No-op if already on.
  - `nfcStop()` → disables it, closes any open tag.
  - `nfcGetState()` → `{"hasHardware": bool, "enabled": bool}`
  - `openNfcSettings()` → launches `Settings.ACTION_NFC_SETTINGS`
- Produces (event channel `nfc_hub/events`), each a `Map`:
  - `{"type":"tagDiscovered","handle":Int,"hint":String,"uid":hex,"atqa":hex?,"sak":Int?,"atqb":hex?,"historicalBytes":hex?,"pmm":hex?}`
  - `{"type":"tagLost","handle":Int}`
  - `{"type":"nfcStateChanged","enabled":Bool}`
  `hint` is one of `type2|mifareClassic|felica|isoDep|typeB`, mapping 1:1 onto Dart's `TagTechHint`.

- [ ] **Step 1: Manifest**

`android/src/main/AndroidManifest.xml`:
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.cheqplease.nfchub">
  <uses-permission android:name="android.permission.NFC"/>
  <!-- required=false: USB-reader-only devices must still install. -->
  <uses-feature android:name="android.hardware.nfc" android:required="false"/>
</manifest>
```

- [ ] **Step 2: Write `NfcReaderMode.kt`**

```kotlin
package com.cheqplease.nfchub

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.*
import java.io.IOException

/** A discovered tag: its handle, its family, and the identity fields that
 *  are free (no connect() required). */
data class DiscoveredTag(
    val handle: Int,
    val hint: String,
    val uid: ByteArray,
    val atqa: ByteArray?,
    val sak: Int?,
    val atqb: ByteArray?,
    val historicalBytes: ByteArray?,
    val pmm: ByteArray?
)

class TagLostError(message: String) : Exception(message)

/**
 * Owns NfcAdapter reader mode and the live tag session.
 *
 * Session model: exactly ONE tag is live at a time. Its tech is connected
 * LAZILY (on first read) and HELD until the tag leaves the field, so the
 * Dart drivers can drive multi-step reads exactly as they do over CCID.
 * Android permits only one connected tech per Tag, so the tech is chosen
 * once, from the tech list, at discovery.
 */
class NfcReaderMode(
    private val activity: Activity,
    private val onDiscovered: (DiscoveredTag) -> Unit
) {
    private val adapter: NfcAdapter? = NfcAdapter.getDefaultAdapter(activity)

    private var nextHandle = 1
    private var currentHandle: Int? = null
    private var currentTag: Tag? = null
    private var connected: TagTechnology? = null

    fun hasHardware(): Boolean = adapter != null
    fun isEnabled(): Boolean = adapter?.isEnabled == true

    fun start() {
        val a = adapter ?: return
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        a.enableReaderMode(activity, { tag -> onTag(tag) }, flags, null)
    }

    fun stop() {
        adapter?.disableReaderMode(activity)
        closeCurrent()
    }

    private fun onTag(tag: Tag) {
        closeCurrent()
        val handle = nextHandle++
        currentHandle = handle
        currentTag = tag

        val techs = tag.techList.toSet()
        val nfcA = NfcA.get(tag)
        val nfcB = NfcB.get(tag)
        val nfcF = NfcF.get(tag)
        val isoDep = IsoDep.get(tag)

        // Order matters: MifareClassic and IsoDep both also expose NfcA.
        val hint = when {
            techs.contains(MifareClassic::class.java.name) -> "mifareClassic"
            techs.contains(IsoDep::class.java.name) -> "isoDep"
            techs.contains(NfcF::class.java.name) -> "felica"
            techs.contains(MifareUltralight::class.java.name) ||
                techs.contains(NdefFormatable::class.java.name) ||
                techs.contains(Ndef::class.java.name) -> "type2"
            techs.contains(NfcB::class.java.name) -> "typeB"
            techs.contains(NfcA::class.java.name) -> "type2" // bare NfcA: assume Type 2
            else -> "isoDep"
        }

        // ATQB is not exposed directly; ISO14443-3 defines it as
        // '50' | PUPI(4) | AppData(4) | ProtocolInfo(3) = 12 bytes.
        val atqb: ByteArray? = if (nfcB != null)
            byteArrayOf(0x50) + tag.id + nfcB.applicationData + nfcB.protocolInfo
        else null

        onDiscovered(
            DiscoveredTag(
                handle = handle,
                hint = hint,
                uid = tag.id,
                atqa = nfcA?.atqa,
                sak = nfcA?.sak?.toInt(),
                atqb = atqb,
                historicalBytes = isoDep?.historicalBytes,
                pmm = nfcF?.manufacturer
            )
        )
    }

    /** Connects the tech this tag was classified as, if not already open. */
    private fun ensureConnected(handle: Int): TagTechnology {
        if (handle != currentHandle) throw TagLostError("Tag $handle is gone")
        val tag = currentTag ?: throw TagLostError("Tag $handle is gone")
        connected?.let { if (it.isConnected) return it }

        val tech: TagTechnology = MifareClassic.get(tag)
            ?: IsoDep.get(tag)
            ?: NfcF.get(tag)
            ?: NfcA.get(tag)
            ?: NfcB.get(tag)
            ?: throw TagLostError("No usable technology on tag $handle")
        try {
            tech.connect()
        } catch (e: IOException) {
            throw TagLostError("Failed to connect: ${e.message}")
        }
        connected = tech
        return tech
    }

    /** Raw transceive on whichever tech is connected. */
    fun transceive(handle: Int, data: ByteArray): ByteArray {
        val tech = ensureConnected(handle)
        return try {
            when (tech) {
                is IsoDep -> tech.transceive(data)
                is NfcA -> tech.transceive(data)
                is NfcF -> tech.transceive(data)
                is NfcB -> tech.transceive(data)
                is MifareClassic -> tech.transceive(data)
                else -> throw TagLostError("Tech cannot transceive")
            }
        } catch (e: IOException) {
            throw TagLostError("Transceive failed: ${e.message}")
        }
    }

    fun mifareAuthenticate(handle: Int, sector: Int, keyA: Boolean, key: ByteArray): Boolean {
        val tech = ensureConnected(handle)
        val mc = tech as? MifareClassic ?: throw TagLostError("Not a MIFARE Classic tag")
        return try {
            if (keyA) mc.authenticateSectorWithKeyA(sector, key)
            else mc.authenticateSectorWithKeyB(sector, key)
        } catch (e: IOException) {
            throw TagLostError("Auth failed: ${e.message}")
        }
    }

    fun mifareReadBlock(handle: Int, block: Int): ByteArray {
        val tech = ensureConnected(handle)
        val mc = tech as? MifareClassic ?: throw TagLostError("Not a MIFARE Classic tag")
        return try {
            mc.readBlock(block)
        } catch (e: IOException) {
            throw TagLostError("Read failed: ${e.message}")
        }
    }

    private fun closeCurrent() {
        try { connected?.close() } catch (_: Exception) {}
        connected = null
        currentTag = null
        currentHandle = null
    }
}
```

- [ ] **Step 3: Wire it into `NfcHubPlugin.kt`**

Add (keeping every existing USB/CCID member and method exactly as-is):
- an `EventChannel("nfc_hub/events")` with a `StreamHandler` holding an `EventSink`, plus a `Handler(Looper.getMainLooper())` — **`EventSink.success()` must be called on the main thread**, and `onTagDiscovered` fires on a binder thread.
- an `NfcReaderMode` instance, created in `onAttachedToActivity` and stopped in `onDetachedFromActivity`.
- `onMethodCall` cases: `nfcStart`, `nfcStop`, `nfcGetState`, `nfcTransceive` (args `handle`, `data` hex → returns hex), `nfcMifareAuth` (args `handle`, `sector`, `keyA`, `key` hex → Bool), `nfcMifareReadBlock` (args `handle`, `block` → hex), `openNfcSettings`.
- Map `TagLostError` → `result.error("TAG_LOST", message, null)`.
- Register a `BroadcastReceiver` for `NfcAdapter.ACTION_ADAPTER_STATE_CHANGED` and emit `nfcStateChanged`.
- Emit `tagLost` when a transceive throws `TagLostError`.

- [ ] **Step 4: Verify it compiles**

```bash
cd /Users/akashshahriar/StudioProjects/ccid/example
flutter build apk --debug
```
Expected: BUILD SUCCESSFUL. (There is no Dart caller yet — Task 4 adds it. The gate here is that the Kotlin compiles and the existing CCID path still builds.)

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test 2>&1 | tail -1   # still 116+, unchanged
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(android): add NfcAdapter reader mode and tag session handling

Lazy-connect, held-until-lost session model, so Dart drivers can drive
multi-step reads over the built-in antenna exactly as they do over CCID."
```

---

### Task 3: Dart — `AndroidNfcBackend` implementing the five transports

**Files:**
- Create: `lib/src/transport/android_backend.dart`
- Create: `test/transport/android_backend_test.dart`

**Interfaces:**
- Consumes: `TagBackend` (Task 1), the method channel from Task 2.
- Produces: `AndroidNfcBackend implements TagBackend`, constructed from a discovery event's identity fields + handle.

**THE MAPPING TABLE — this is the task.** Every row is the whole job:

| Transport member | Android implementation |
|---|---|
| `TagBackend.atr` | **`null`** — the antenna has no ATR |
| `Type2Transport.readUid` | the discovery event's `uid` (free, no I/O) |
| `Type2Transport.readCapabilityContainer` | `nfcTransceive([0x30, 0x03])` → take **first 4 bytes** (the READ returns 16 = pages 3-6) |
| `Type2Transport.readPages(p)` | `nfcTransceive([0x30, p])` → 16 bytes (4 pages) — matches CCID's `Le=0x10` exactly |
| `Type2Transport.getVersion` | `nfcTransceive([0x60])`; on ANY error return **null**, and return null unless the result is **exactly 8 bytes** (the interface contract — `readChipVersion` parses with no length guard) |
|