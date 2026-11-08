# Security policy

## Supported versions

Security fixes go into the latest published release of `nfc_hub`.

## Reporting a vulnerability

Please do not open a public issue. Report the problem privately through
[GitHub's vulnerability reporting](https://github.com/AkashShahriar55/nfc-hub/security/advisories/new),
and include the affected version, the hardware involved, and steps to
reproduce.

## Scope

`nfc_hub` passes tag data and keys between your app, the Android NFC stack, and
USB readers. Handling keys securely and validating tag contents remain your
app's responsibility. MIFARE Classic's authentication is cryptographically
broken, so do not rely on it to protect sensitive data.
