# Example App Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the example app as a real test harness for `nfc_hub`: it auto-detects tags via `tagStream()` and shows each one's info immediately, surfaces live dual-source connection state, exposes every driver's family-specific reads behind clear actions, makes failures visible and copyable — and it's the device on which the outstanding Plan 1/2/3 hardware gates get run. Also fixes the one Important bug Plan 3 deferred here.

**Architecture:** Plan 4 of 4. Plan 3 shipped the unified API (`tagStream`/`readTag`/`connectionState`/`openNfcSettings`) on `NfcHub`. This plan consumes it from a rebuilt example app and fixes the `connectionState`-before-`tagStream` CCID drop (Task 1, a library fix with a Dart test — the app is its manual validation surface). Widgets take injectable streams so the harness is widget-testable, not just build-checked. Aesthetic is clean/functional dev-tool, light+dark.

**Tech Stack:** Flutter 3.38.3, `nfc_hub` (path dep), `flutter_test`. The example keeps its MRT-decode helpers (`mrt_transaction.dart`, `mrt_stations.dart`).

## Global Constraints

- **Seamlessness on screen:** a tag from the phone antenna and a card on a reader must appear and read identically. The UI labels the source (for debugging) but the read actions and their results are the same code path for both — no per-source branching in a read action.
- **Auto-detect is the default loop:** the home screen listens to `tagStream()` from launch; a tap/seat surfaces the tag with its `TagInfo` filled in, no button press. Heavy/slow reads (memory dump, NDEF, MRT history, DESFire) sit behind explicit buttons on the tag detail screen.
- **Failures must be visible and copyable.** Every read action shows its result OR its error inline (never a silent nothing, never a red screen). All hex/result text is selectable. This is a debugging tool — a failure you can't read or copy is a failure of the harness.
- **Injectable for testing.** Widgets that consume `NfcHub` take the relevant `Stream`s (or a small facade) as constructor params, defaulting to a real `NfcHub`'s streams, so widget tests pass fakes. No widget calls `NfcHub()` directly in its build path except the top-level wiring in `main.dart`.
- **Library scope is ONE change:** Task 1's `CcidSource` fix. Everything else is `example/`. Do NOT change drivers, transports, the Android backend, or the public API surface.
- **Test baseline: 204 passing, 0 failing** (library). Plus the example's own tests. Counts may only go up. The example currently has a stale `widget_test.dart` (a plugin-template "platform version" test against the old `MyApp`) — it will be replaced.
- `flutter analyze` clean. Note the example uses `flutter_lints: ^3.0.0` (older than the library's `^5.0.0`); the 2 pre-existing info-lints in `example/test/mrt_transaction_test.dart` are expected — do not introduce new ones.
- Every task: `example` must `flutter build apk --debug` successfully.
- Do NOT touch `LICENSE`. Do NOT disturb `.pubignore` (the example is already excluded from the published package via `docs/`-style rules; the example app is `publish_to: none`).

## Roadmap

- Plans 1-3 (done): rename to `nfc_hub`; transport abstraction; built-in NFC + unified API. Released 0.6.0, pending hardware validation.
- **Plan 4 (this document):** rebuild the example app as the test harness; fix the deferred CCID drop.

## The outstanding hardware gates this harness exists to run

After Plan 4, the harness is the tool for these (carried from Plans 1-3, all still open):
1. Built-in NFC end-to-end: tap a tag → discovery + reads; pull a card mid-read → clean `TagLostException`; screen-rotate with reader mode active.
2. ACR122U regression: the reader path still works (Gates 1/2 passed pre-Plan-3; confirm no regression).
3. CCID auto-detect + USB-permission-dialog interaction (the poll loop's connect-per-tick).
4. Type B / DESFire (no test cards; unvalidated anywhere).

## File Structure

```
example/lib/main.dart                 # REPLACE: MaterialApp (light+dark) + HarnessHome
example/lib/harness_home.dart         # NEW: status header + tagStream() live tag list
example/lib/connection_status_bar.dart# NEW: connectionState()-driven header + Enable-NFC action
example/lib/tag_detail_page.dart      # REPLACE tag_details_page.dart: TagInfo + per-family read actions
example/lib/widgets/result_tile.dart  # NEW: selectable-hex / labelled result + error tile
example/lib/mrt_transaction.dart      # KEEP (MRT decode)
example/lib/mrt_stations.dart         # KEEP
example/test/connection_status_bar_test.dart # NEW widget test
example/test/harness_home_test.dart          # NEW widget test
example/test/widget_test.dart         # REPLACE the stale platform-version test
example/test/mrt_transaction_test.dart# KEEP
```

---

### Task 1: Fix the `connectionState`-before-`tagStream` CCID drop (library + Dart test)

Plan 3's final review found: `CcidSource`'s `tags`/`taggedTags`/`readerStates` share one listener count, and the connect→identify→emit path runs whenever ANY is listening. So if `connectionState()` (via `readerStates`) is listened to before `tagStream()` (via `tags`), a card seated in that window is emitted to a broadcast `tags` controller with no listener → dropped → reader marked `occupied` → never re-emitted. The harness's status-bar-then-read flow hits this exactly.

**Files:**
- Modify: `lib/src/source/ccid_source.dart`
- Modify: `test/source/ccid_source_test.dart`

**Interfaces:**
- Consumes: the existing `CcidSource` from Plan 3.
- Produces: no API change. `CcidSource` behaves so a card present when `tags()` starts listening is delivered to that listener, regardless of whether `readerStates()` was already driving the loop.

- [ ] **Step 1: Confirm baseline**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test 2>&1 | tail -1
```
Expected: 204 passing.

- [ ] **Step 2: Write the failing test** in `test/source/ccid_source_test.dart` (reuse the file's existing fake platform + `FakeAsync`/real-timing seam):

```dart
test('a card present before tags() is listened is delivered to a late '
    'tags() subscriber (readerStates was already driving the loop)', () {
  // Regression: connectionState() (readerStates) listened first must not
  // consume the card such that a later tagStream() (tags) never sees it.
  fakeAsync((async) {
    final platform = _FakePlatform()
      ..readers = ['reader-1']
      ..cardOn('reader-1'); // a Type 2 card seated from the start
    final source = CcidSource(platform, pollInterval: const Duration(milliseconds: 100));

    // Only readerStates is listened first (what connectionState does).
    final states = <List<ExternalReaderState>>[];
    final stateSub = source.readerStates().listen(states.add);
    async.elapse(const Duration(milliseconds: 250)); // a few ticks

    // Now the app starts tagStream().
    final tags = <TagDriver>[];
    final tagSub = source.tags().listen(tags.add);
    async.elapse(const Duration(milliseconds: 250));

    expect(tags, isNotEmpty,
        reason: 'the card present when tags() started listening must be '
            'delivered to it');
    stateSub.cancel();
    tagSub.cancel();
    source.dispose();
  });
});
```

- [ ] **Step 3: Run it, confirm it fails** (the late `tags()` subscriber gets nothing).

```bash
flutter test test/source/ccid_source_test.dart -p vm --name "late tags"
```

- [ ] **Step 4: Implement the fix.**

Choose the simpler correct approach: **hold the built driver for each occupied reader, and replay the currently-occupied readers' drivers to a `tags()`/`taggedTags()` subscriber that attaches while the reader is already occupied.** Concretely:
- Keep a `final Map<String, TagDriver> _occupiedDrivers = {}` (and, for `taggedTags`, the reader name is the key already). Populate it when a reader becomes `occupied` (alongside the existing emit), clear the entry when it goes `empty`/vanishes/disposed.
- On the `tags` controller's `onListen` (and `taggedTags`' `onListen`), synchronously replay: for each currently-occupied reader, `add` its held driver (wrapped as `ReaderTaggedDriver` for `taggedTags`) to that controller.
- **Guard against double-delivery to existing listeners:** a broadcast `add` reaches ALL current listeners. To replay only to the newly-attached one without re-hitting others, deliver the replay via a microtask that targets only the new subscription — the clean way is to NOT use a shared broadcast for replay but to build each `tags()`/`taggedTags()` return as `Stream.multi` (or a per-subscription wrapper) that first yields the held drivers then follows the live controller. If `Stream.multi` is too heavy, an acceptable simpler alternative: make `tags()` return `Stream<TagDriver>` composed as `() async* { yield* _replayOccupied(); yield* _tagsController.stream; }` PER CALL — but beware that mixing a one-shot replay with a broadcast tail can drop events between the two; use `StreamGroup.merge` or a controller that buffers until the tail is attached. Pick the approach that the test in Step 2 (plus the existing "emits exactly once", "re-insertion", and simultaneous-listener tests) all pass under, and that does NOT double-deliver to a listener already attached when a second one joins. Document the chosen mechanism in a `///`.
- **Do NOT break the existing invariants:** a card that stays put still emits exactly once to a given listener; two listeners attached from the start still each get one emit; removal→reinsertion still emits anew; `disconnect` on removal/vanish/dispose unchanged.

- [ ] **Step 5: Run the full `ccid_source` suite** — the new test passes AND every prior test still passes (exactly-once, re-insertion, isolation, overlap-guard, disconnect-on-removal/vanish/dispose).

```bash
flutter test test/source/ccid_source_test.dart
flutter test 2>&1 | tail -1   # >= 205
```

- [ ] **Step 6: Commit**

```bash
git add lib/src/source/ccid_source.dart test/source/ccid_source_test.dart
git commit -m "fix: deliver an already-seated CCID card to a late tagStream() listener

CcidSource's tags/taggedTags/readerStates shared one listener count, so a card
seated while only connectionState() (readerStates) was listening got emitted to a
broadcast tags controller with no listener and dropped, then never re-emitted.
Hold each occupied reader's driver and replay it to a tags()/taggedTags()
subscriber that attaches while the reader is already occupied."
```

---

### Task 2: Reusable result tile + the connection-status bar

Two building blocks. `ResultTile` shows a labelled result with selectable/copyable body or an error, used everywhere reads are displayed. `ConnectionStatusBar` is the live dual-source header driven by `connectionState()`.

**Files:**
- Create: `example/lib/widgets/result_tile.dart`
- Create: `example/lib/connection_status_bar.dart`
- Create: `example/test/connection_status_bar_test.dart`

**Interfaces:**
- Produces:
  - `ResultTile({required String title, String? value, Object? error, bool loading})` — shows `title`; if `loading`, a spinner; if `error != null`, the error in an error style (selectable); else `value` in a monospace, selectable body. Value/error are `SelectableText`.
  - `ConnectionStatusBar({Stream<CcidConnectionState>? states, Future<void> Function()? onEnableNfc})` — subscribes to `states` (default: a real `NfcHub().connectionState()`), renders: a built-in-NFC chip (ready / disabled+`Enable` button / no-hardware / unknown-while-waiting), and one chip per `ExternalReaderState` (reader name + a filled/hollow dot for `cardPresent`). The `Enable` button calls `onEnableNfc` (default: `NfcHub().openNfcSettings`). `states` injectable so the widget test drives it.

- [ ] **Step 1: Write `result_tile.dart`.**

```dart
import 'package:flutter/material.dart';

/// A labelled result row for the harness: a title plus either a spinner
/// (loading), a selectable error, or a selectable monospace value. Used for
/// every read so a failure is always visible and copyable.
class ResultTile extends StatelessWidget {
  const ResultTile({
    super.key,
    required this.title,
    this.value,
    this.error,
    this.loading = false,
  });

  final String title;
  final String? value;
  final Object? error;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (error != null) {
      body = SelectableText(
        'Failed: $error',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
      );
    } else {
      body = SelectableText(
        value ?? '(none)',
        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Write the failing widget test** `connection_status_bar_test.dart` — pump `ConnectionStatusBar` with a `StreamController<CcidConnectionState>` and assert the rendered content for three states:
  - `builtInNfcAvailable: true` → shows a "NFC ready" indicator, no Enable button.
  - `builtInNfcReason == NfcUnavailableReason.disabled` → shows an "Enable" button; tapping it invokes the injected `onEnableNfc`.
  - `externalReaders: [ExternalReaderState('ACR122U', true)]` → shows "ACR122U" and a card-present indicator.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub_example/connection_status_bar.dart';

void main() {
  testWidgets('disabled NFC shows an Enable button that calls onEnableNfc',
      (tester) async {
    final controller = StreamController<CcidConnectionState>.broadcast();
    var enableCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConnectionStatusBar(
          states: controller.stream,
          onEnableNfc: () async => enableCalled = true,
        ),
      ),
    ));
    controller.add(const CcidConnectionState(
      builtInNfcAvailable: false,
      builtInNfcReason: NfcUnavailableReason.disabled,
      externalReaders: [],
    ));
    await tester.pump();
    expect(find.text('Enable'), findsOneWidget);
    await tester.tap(find.text('Enable'));
    expect(enableCalled, isTrue);
    await controller.close();
  });

  testWidgets('shows an attached reader with card-present state',
      (tester) async {
    final controller = StreamController<CcidConnectionState>.broadcast();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConnectionStatusBar(states: controller.stream)),
    ));
    controller.add(const CcidConnectionState(
      builtInNfcAvailable: true,
      builtInNfcReason: NfcUnavailableReason.none,
      externalReaders: [ExternalReaderState('ACR122U', true)],
    ));
    await tester.pump();
    expect(find.textContaining('ACR122U'), findsOneWidget);
    await controller.close();
  });
}
```
(Add the `dart:async` import.) **Confirm `CcidConnectionState`'s constructor signature** against `lib/src/nfc_hub_api.dart` before writing this — use the real field names/positional-vs-named form. If it differs, match the real one.

- [ ] **Step 3: Run, confirm failure** (`ConnectionStatusBar` undefined).

- [ ] **Step 4: Implement `connection_status_bar.dart`** to satisfy the tests — a `StatefulWidget` subscribing to `states` in `initState` (cancel in `dispose`), storing the latest `CcidConnectionState`, rendering a `Wrap` of chips. Guard `setState` with `mounted`. The `Enable` button appears only when `builtInNfcReason == disabled`. Default `states`/`onEnableNfc` to a lazily-created `NfcHub()`'s `connectionState()`/`openNfcSettings` when not injected.

- [ ] **Step 5: Verify** (`flutter test example/test/connection_status_bar_test.dart` from `example/`, `flutter analyze`, `example` builds).

- [ ] **Step 6: Commit** `"feat(example): add ResultTile and the connectionState-driven status bar"`.

---

### Task 3: The harness home — `tagStream()` auto-detect list

The home screen: the status bar on top, and below it a live list of detected tags (most recent first) sourced from `tagStream()`. Each entry shows the tag's family, source, UID, and taps through to the detail page. Detection is automatic — no Read button.

**Files:**
- Create: `example/lib/harness_home.dart`
- Create: `example/test/harness_home_test.dart`

**Interfaces:**
- Consumes: `ConnectionStatusBar` (Task 2), the tag detail page (Task 4 — for now navigate to a placeholder, wire the real page in Task 5, OR build Task 4 first; the plan orders 3 before 4, so navigate to a minimal inline detail until Task 4 replaces it — see Step 4).
- Produces: `HarnessHome({Stream<TagDriver>? tags, Stream<CcidConnectionState>? connectionState})` — both injectable (default to a real `NfcHub`'s `tagStream()`/`connectionState()`), so the widget test drives detection with a fake stream.

- [ ] **Step 1: Write the failing widget test** `harness_home_test.dart`:
  - pump `HarnessHome` with a `StreamController<TagDriver>` for `tags` and a dummy `connectionState` stream.
  - emit a fake `TagDriver` (a real driver subtype over a fake transport — reuse a fake transport from the library's own test doubles if importable, else a minimal local fake) → assert the list shows an entry with the tag's technology/UID.
  - emit a second tag → assert both appear (most-recent-first ordering).

  To make a `TagDriver` cheaply: construct e.g. `Type2Tag(fakeType2Transport, atr: ...)` where the fake transport returns a scripted UID, then the home reads `readTagInfo()` to display it. (The home should call `readTagInfo()` on each detected tag to populate its summary row — this is the "show info immediately" behavior.) Keep the fake transport minimal and local to the test.

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Implement `harness_home.dart`.**
  - `StatefulWidget`; in `initState`, subscribe to `tags` (default `NfcHub().tagStream()`); for each emitted `TagDriver`, `await driver.readTagInfo()` (best-effort, in a try/catch — a failed info read still lists the tag with the error) and prepend a summary record `{driver, info-or-error, source-label}` to a list; `setState` guarded by `mounted`.
  - Body: `Column` of `ConnectionStatusBar(states: connectionState)` then `Expanded(ListView.builder(...))` of tag rows. Each row: leading icon by family, title = `info.technology` (or the runtime type on error), subtitle = `UID: <hex>` + source label; `onTap` → push the detail page for that driver.
  - Handle the empty state ("Tap a tag or place a card on a reader…").
  - Cancel the subscription in `dispose`.
  - **Source label:** `TagDriver` doesn't carry its source (by design — seamlessness). If a per-tag source label is wanted, derive it only if cheaply available; otherwise omit it rather than adding source-tracking to the driver. (The status bar already shows which sources are live.) Keep the row focused on family + UID.

- [ ] **Step 4: Navigation.** `onTap` pushes `TagDetailPage(driver: driver)`. Since Task 4 builds that page, for THIS task push a minimal placeholder (`Scaffold` showing `driver.runtimeType`) and leave a `// TODO(task4): real detail page` — Task 5 wires the real one. (Do not block Task 3 on Task 4.)

- [ ] **Step 5: Verify** (widget test, analyze, `example` builds).

- [ ] **Step 6: Commit** `"feat(example): tagStream() auto-detect home screen with live tag list"`.

---

### Task 4: The tag detail page — TagInfo + per-family read actions

Rework the old `tag_details_page.dart` into `tag_detail_page.dart`: the tag's `TagInfo` up top (auto-loaded), then explicit buttons for the heavy/family-specific reads, each rendering through `ResultTile` (selectable value or visible error). This is the same behavior for a phone-tapped and reader-placed tag of the same family.

**Files:**
- Create: `example/lib/tag_detail_page.dart`
- Delete: `example/lib/tag_details_page.dart` (the old one)

**Interfaces:**
- Consumes: `ResultTile` (Task 2); the MRT helpers (`parseTransactionBlocks`, `stationName`); the driver types + `readTagInfo()`.
- Produces: `TagDetailPage({required TagDriver driver})`.

- [ ] **Step 1: Build the page.** `StatefulWidget`. In `initState`, load `TagInfo` (auto): `await driver.readTagInfo()` into a `ResultTile` state (loading→value/error). Then a set of action buttons determined by the driver's concrete type (`if (driver is Type2Tag) ...`), each button running a read into its own `ResultTile` state. **Guard every `setState` with `mounted`** (reads are multi-second). Run reads sequentially per button press; do not fire all on load (heavy reads like memory dump are opt-in).

  Per family (mirror the old page's coverage, but behind buttons and through `ResultTile`):
  - **Type2Tag:** buttons for UID, Capability Container, NDEF (`readNdef()` → records joined), Memory Dump (`readMemoryDump()` → paged hex), Chip Version.
  - **MifareClassicTag:** button "Read Sector 0" → `authenticateWithDefaultKeys(0)` then `readSector(0)` → blocks hex; surface `MifareAuthException` as the tile's error.
  - **FelicaTag:** buttons IDm, and "Transactions" → `readWithoutEncryption(0x220F, [0,1,2,3])`, then `parseTransactionBlocks(result.blocks)` formatted via `stationName` (reuse the kept helpers); if `!result.isSuccess`, show the status flags as the value (not an error — it's a valid card response).
  - **IsoDepTag:** button "SELECT (empty AID)" → `selectApplication('')`; button "DESFire GetVersion" → `readDesfireVersion()` (best-effort; most non-DESFire cards error — show it).
  - **TypeBTag:** just the auto TagInfo (PUPI/ATQB) — no extra read actions.

- [ ] **Step 2: Selectable + copyable.** All result bodies are `ResultTile`'s `SelectableText`. Hex uses a shared `_hex(List<int>)` helper (copy the old page's). No `Text` for results.

- [ ] **Step 3: Delete the old page** (`git rm example/lib/tag_details_page.dart`) and update any import of it.

- [ ] **Step 4: Verify** — `flutter analyze`, `example` builds. (A widget test here is optional; if cheap, add one that pumps `TagDetailPage` with a fake-transport `Type2Tag` and asserts the TagInfo tile loads. Not required — the detail page's real proof is the hardware gate.)

- [ ] **Step 5: Commit** `"feat(example): tag detail page with per-family reads through ResultTile"`.

---

### Task 5: Wire `main.dart`, rewrite the stale test, README, final verification

**Files:**
- Modify: `example/lib/main.dart` (REPLACE the old manual UI)
- Modify: `example/lib/harness_home.dart` (point navigation at the real `TagDetailPage`)
- Modify: `example/test/widget_test.dart` (REPLACE the stale platform-version test)
- Modify: `README.md` (usage snippet → the new `tagStream()` flow) and/or `example/README.md`

- [ ] **Step 1: `main.dart`.** A light+dark `MaterialApp` (`ThemeData`/`ThemeData.dark`, `themeMode: ThemeMode.system`, a `ColorScheme.fromSeed`) whose `home` is `HarnessHome()` (using the real `NfcHub` streams by default). Remove the old `_MyHomePageState` manual reader/APDU UI entirely. Keep `MyApp` as the class name IF the example test references it, else name it clearly.

- [ ] **Step 2: Real navigation.** In `harness_home.dart`, replace the Task-3 placeholder navigation with `MaterialPageRoute(builder: (_) => TagDetailPage(driver: driver))`. Remove the `TODO(task4)`.

- [ ] **Step 3: Replace `widget_test.dart`.** The old test pumps `MyApp` and looks for a "platform version" — stale. Replace with a smoke test: pump the app with INJECTED empty/fake streams (so it doesn't touch real platform channels in the test), assert the harness home renders (the empty-state text and the status bar). If `main.dart`'s `MyApp` builds `HarnessHome()` with real streams, either add a `@visibleForTesting` constructor param to inject streams, or test `HarnessHome` directly with fakes (preferred — leave `main.dart` thin). Ensure `flutter test` in `example/` passes.

- [ ] **Step 4: README.** Update the top-level `README.md` usage sample to show the seamless flow:
```dart
import 'package:nfc_hub/nfc_hub.dart';

final hub = NfcHub();
await for (final tag in hub.tagStream()) {
  final info = await tag.readTagInfo();
  print('${info.technology} — UID ${info.uid}');
  // family-specific reads, identical whether the tag came from the
  // phone's antenna or a USB CCID reader:
  if (tag is Type2Tag) print(await tag.readNdef());
}
```
Keep the existing CCID/reader install prerequisites. Add a one-liner that the example app is a full harness (auto-detect, connection status, per-family reads). Verify the snippet compiles via the scratch-file method (drop it in `example/lib/`, `flutter analyze`, delete).

- [ ] **Step 5: Full verification.**
```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test 2>&1 | tail -1                    # library >= 205
(cd example && flutter test 2>&1 | tail -1)     # example tests pass
(cd example && flutter build apk --debug)       # BUILD SUCCESSFUL
flutter pub publish --dry-run 2>&1 | tail -3    # still 0 warnings (example is excluded)
```

- [ ] **Step 6: Commit** `"feat(example): wire the harness home as the app entry, refresh README"`.

---

## Definition of Done

- `flutter analyze` clean; library `flutter test` ≥ 205; `example` tests pass; `example` APK builds; `flutter pub publish --dry-run` 0 warnings.
- The deferred CCID drop is fixed and regression-tested (a card present when `tagStream()` starts listening is delivered even if `connectionState()` was listened first).
- The harness: auto-detects tags via `tagStream()` and shows `TagInfo` immediately; shows live dual-source connection state with an Enable-NFC action; exposes per-family reads through selectable/copyable `ResultTile`s with visible errors; works light+dark; no `Row` overflow on a phone width.
- The old manual reader/APDU UI is gone.
- **HARDWARE GATE (the point of this whole plan — run on a device after it lands):** tap a tag on the phone → it appears with info and per-family reads work; place each known-good card on the ACR122U → same; pull a card mid-read → a visible `TagLostException`, not a crash; toggle NFC off → the Enable button appears and deep-links; confirm the ACR122U path is not regressed. Type B/DESFire remain unvalidated pending cards.
