# Manual verification

Everything below runs against **your real recordings**, which is why no agent may run it
(see the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-voicememos-mcp
```

## 0 — Before you start

In Voice Memos, record three short memos you do not mind reading in plain text:

| Memo | Contents | Why |
|---|---|---|
| `ZZ Short` | ten seconds, one clear sentence | the normal path |
| `ZZ Long` | two or three minutes | the slow path |
| `ZZ Quiet` | five seconds of near-silence | the empty-transcript case |

Put `ZZ Quiet` in a folder, so the folder field has something to show. Delete all three when
you finish.

Set an export root in the extension settings — a scratch folder, not your Documents.

## 1 — Where the recordings are, and whether they can be read

This server reads files, so the failure to rule out first is a permission one.

| Step | Call | Expected |
|---|---|---|
| 1.1 | `recordings_status` | Reports the library path it is using and whether it can read it. |
| 1.2 | If it reports the folder as unreadable | Grant Full Disk Access to the installed binary, restart Claude Desktop, call again. |
| 1.3 | Read the output carefully | An **unreadable** library and an **empty** one are reported differently. |
| 1.4 | `recordings_status` before granting Speech Recognition | Reports transcription as not yet permitted, naming System Settings → Privacy & Security → Speech Recognition. |

Step 1.3 is the check worth making deliberately. If a missing permission renders as "no
recordings", the server is lying about your library.

The binary to grant lives at
`~/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.apple-voicememos-mcp/server/apple-voicememos-mcp`.

## 2 — Listing

| Step | Call | Expected |
|---|---|---|
| 2.1 | `recordings_list` | All three memos, newest first, with dates and durations. |
| 2.2 | Compare the names with Voice Memos | They match the **titles you typed**, not the timestamp filenames. |
| 2.3 | `recordings_list` with `folder` | Only `ZZ Quiet`. |
| 2.4 | `name_contains` | Narrows correctly. |
| 2.5 | `created_after` and `created_before` naming the **same day** | Includes memos recorded any time that day. |
| 2.6 | `recording_get` on one | Duration, dates, folder, file size. |

Step 2.2 is the metadata read. If you see `20260809 121500` instead of a title, the audio's
common metadata is not being read and the listing is far less useful than it should be.

Step 2.5 catches the off-by-one-day: a plain day as the upper bound must cover that whole
day, or a one-day window is always empty.

## 3 — Transcription

| Step | Call | Expected |
|---|---|---|
| 3.1 | `recording_transcribe` on `ZZ Short` | The Speech Recognition dialog appears the first time. |
| 3.2 | Approve, then call again | Text that matches what you said. |
| 3.3 | **Turn off Wi-Fi and Ethernet**, then transcribe `ZZ Long` | **It still works.** Recognition is on-device. |
| 3.4 | Time it | Slow — roughly proportional to the recording. This is expected. |
| 3.5 | `recording_transcribe` on `ZZ Quiet` | Reports that nothing was recognised, rather than returning an empty string as if it were the answer. |
| 3.6 | Transcribe more recordings in one call than the configured maximum | Refused, or capped and said so. |
| 3.7 | Transcribe `ZZ Long` twice | The second call is immediate — the transcript cache under `$TMPDIR` already has it. |
| 3.8 | Inspect the cache folder named in `recordings_status` | One file per recording, named by hash, not by path. |

Step 3.3 is the one that matters. If transcription fails with the network off, it is being
sent to a server, and that is a different piece of software from the one this repository is
supposed to be.

## 4 — Export

| Step | Call | Expected |
|---|---|---|
| 4.1 | `recording_export` of `ZZ Short` into the export root | The audio file appears there and plays. |
| 4.2 | `recording_export` to a path **outside** the export root | Refused, naming the configured root. |
| 4.3 | `recording_export` with no export root configured | Refused, saying so. |
| 4.4 | Check Voice Memos afterwards | All three memos still there, unmodified. |

## 5 — What is deliberately absent

| Step | Call | Expected |
|---|---|---|
| 5.1 | Look for a delete, rename or record tool | There is none. This server reads and transcribes; it does not manage the library. |

## 6 — Packaging

| Step | Command | Expected |
|---|---|---|
| 6.1 | `grep -m1 '^NAME=' scripts/pack.sh` | `NAME="apple-voicememos-mcp"` — **check this**, it was once wrong and packed the calendar binary while reporting success. |
| 6.2 | `otool -P .build/release/apple-voicememos-mcp \| grep -E 'NSSpeechRecognition\|NSAppleEvents'` | Both keys present. |
| 6.3 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 6.4 | `codesign -dv extension/server/apple-voicememos-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 6.5 | Install, restart Claude Desktop | Five switches appear, one per tool. |

## 7 — Clean up

Delete `ZZ Short`, `ZZ Long` and `ZZ Quiet` in Voice Memos, empty its Recently Deleted, and
clear the export folder. The transcript cache lives under `$TMPDIR` and needs no manual
cleanup, but a transcript is text that outlives the recording it came from, so delete it too
if that matters to you.
