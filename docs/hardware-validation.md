# Hardware validation — 0.7.0 reliability release

Device: ____  Reader: ACR122U  Date: ____

| # | Scenario | Expected | Pass |
|---|----------|----------|------|
| 1 | Deny USB permission, then re-attach reader and grant | Poll loop keeps running; reader works after re-attach | |
| 2 | Seat card, leave it, restart session (navigate away/back) | Card is NOT re-delivered | |
| 3 | Seat card, lift, immediately re-seat (<0.5 s) | Second presentation IS delivered (within ~2 poll ticks) | |
| 4 | Tap phone antenna 10× with NTAG213 | Exactly 10 deliveries, no doubles, no misses | |
| 5 | Tap MIFARE Classic 1K on ACR122U 10× | Identified as MIFARE every time; uid/atqa/sak populated every time | |
| 6 | Tap DESFire on ACR122U | desfireVersion populated (GetVersion chain uninterrupted by probe) | |
| 7 | Long MIFARE full-dump read on built-in NFC | No UI jank; no spurious TAG_LOST with tag held still | |
| 8 | Turn NFC off then on while session active | Built-in reads resume without app restart | |
| 9 | Tap an unsupported tag (e.g. ISO15693) | onError fires with UnrecognizedTagException | |
| 10 | Unplug reader mid-read | No crash; readerStates drops the reader; re-plug works | |
