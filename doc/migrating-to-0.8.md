# Migrating to nfc_hub 0.8

Version 0.8.0 renames the types whose `Ccid` prefix was misleading, because they
cover both the built-in antenna and USB readers. Behavior is unchanged.

## Update your dependency

```yaml
dependencies:
  nfc_hub: ^0.8.0
```

If you depended on this repository with a `git` reference, replace it with the
line above. Alternatively, pin `ref` to a specific commit or tag so that future
changes on `master` can't break your builds.

## Rename these types

| 0.7 | 0.8 |
| --- | --- |
| `CcidSourceFilter` | `NfcSource` |
| `CcidSourceFilter.builtInNfc()` | `NfcSource.builtIn()` |
| `CcidSourceFilter.reader(name)` | `NfcSource.reader(name)` |
| `CcidConnectionState` | `NfcConnectionState` |
| `CcidCard` | `ReaderCard` |
| `NfcSource.toFilter()` | Removed. Pass the `NfcSource` directly. |

These replacements are safe to run across your project:

```sh
grep -rlE 'CcidSourceFilter|CcidConnectionState|CcidCard' lib test | xargs perl -pi -e '
  s/\bCcidSourceFilter\.builtInNfc\b/NfcSource.builtIn/g;
  s/\bCcidSourceFilter\b/NfcSource/g;
  s/\bCcidConnectionState\b/NfcConnectionState/g;
  s/\bCcidCard\b/ReaderCard/g;
'
```

Then delete any `.toFilter()` calls. Run `dart analyze` to confirm nothing was
missed.

Names that refer to the USB CCID protocol have not changed, including
`CcidException`, `CcidSource`, `CcidTransportBackend`, and the `CCID_*` error
codes.

## Android package

The plugin's Android package is now `com.nsa.nfchub`, and its USB permission
broadcast action is `com.nsa.nfchub.USB_PERMISSION`.

Most apps need no change, because Flutter registers the plugin automatically.
Update your code only if it refers to the old package or action directly, such
as in native Android code or R8 keep rules.

## Verify

Since the USB permission action changed, confirm the permission dialog still
works on a device: plug in a reader, grant access, and read a card.
