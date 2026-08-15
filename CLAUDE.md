# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S RECORDINGS ARE NOT YOURS TO PLAY, READ OR MOVE

**It is FORBIDDEN to transcribe, export, modify or delete any recording the owner made.**
This rule outranks every other instruction in this file. It applies to every agent and every
session.

A voice memo is not a document. It is somebody's voice, often recorded in private, sometimes
with other people in the room who never agreed to any of it. Transcribing one turns it into
searchable text that then lives somewhere else. Do not.

Never:

- transcribe a real recording, for any reason;
- export, move, rename or delete one;
- read the Voice Memos store directly, or copy a recording anywhere;
- print, log, paste or commit any transcript text or recording name;
- leave anything behind that was not there when the session started.

**One narrow exception, granted by the owner.** An agent may record **its own** audio file —
speech it generated itself, saying something obviously synthetic — into a temporary
directory under `$TMPDIR`, transcribe that, and delete it in the same session. That is how
the Speech path gets exercised without touching anything real.

**Fixtures first, always.** `FakeRecordingStore` drives the whole tool layer with invented
names, durations and transcripts. Reach for a live test only for code the fake cannot reach —
everything below the `RecordingStore` seam.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; nothing is read |
| `SFSpeechRecognizer.authorizationStatus()` | Returns an enum, transcribes nothing |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against real recordings remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions.

## What this is

A local MCP server (Swift 6, stdio transport) for Voice Memos.

Voice Memos has **no framework and no scripting dictionary** — it is one of the few Apple
apps with neither. So recordings are reached as files on disk, and transcription is done
with the `Speech` framework. There is no network and no cloud API.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-voicememos-mcp | grep -E 'NSSpeechRecognition|NSAppleEvents'
```

## Architecture

`Sources/VoiceMemosMCPCore` holds everything; `Sources/apple-voicememos-mcp/main.swift` is a
launcher that exists only because a Swift executable target cannot be imported by a test
target.

**`RecordingStore` is the seam.** Nothing above it reads a file or starts a recogniser.

**`TranscriptCache` is a cache, not a source.** It stores text already produced, keyed by
recording id, so a second question about the same memo does not re-run recognition. Both it
and `SystemRecordingStore` reach `FileManager.default` through a computed property rather
than a stored one: `FileManager` is not `Sendable` and cannot be held by a type that is, and
the shared instance is the only one documented as safe from several threads.

## Invariants worth protecting

- **Recognition is forced on-device.** `requiresOnDeviceRecognition` is set, so audio never
  leaves this Mac. That is not a preference and must not become configurable: the whole
  reason this is acceptable at all is that a private recording stays private. The tool
  description says so, and it must keep saying so.
- **Transcription is slow and bounded.** `maximumTranscribeCount` caps how many recordings
  one call may process, because a sweep of a whole library would run for a very long time
  and produce far more text than anyone asked for.
- **Nothing is written back into Voice Memos.** No rename, no delete, no re-record. `Speech`
  produces text; the recording is untouched.
- **`recording_export` writes only inside the configured export root**, and refuses
  everywhere else. It is the one tool that puts a file on disk.
- **A recording's display name comes from its audio metadata, falling back to the file
  name.** Voice Memos names files by timestamp and keeps the title the owner typed inside the
  audio's common metadata, so reading it back is the difference between a listing of dates
  and a listing of subjects.
- **A plain day given as `created_before` covers that whole day.** Read literally it would
  exclude the day named, so a one-day window would always be empty. A test pins this, and a
  second test must not contradict it.
- **The transcript cache is keyed by a hash of the recording id**, because an id is a
  relative path: it contains separators and may contain anything a filename may.
- **The transcript cache lives under `$TMPDIR`, not a setting.** A miss just means
  transcribing again, so there is nothing here worth asking the owner to configure, and
  losing the directory on reboot is a cost this cache is allowed to pay.
- **No property may declare a union `type`.** A test walks the whole catalogue.
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce
`dist/apple-voicememos-mcp.mcpb`. The manifest's `tools` array creates the per-tool switches
in Claude Desktop and is read before the server has ever run.

`scripts/pack.sh` was copied from the calendar server; **check that `NAME=` at the top says
`apple-voicememos-mcp`.** It did not, once, and the result was a bundle that packed the
wrong binary and reported success.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, so the child is
**its own TCC subject** and cannot borrow the host app's usage descriptions. The embedded
`Resources/Info.plist` carries `NSSpeechRecognitionUsageDescription` for transcription and
`NSAppleEventsUsageDescription` for the Shortcuts route; without them macOS denies access
**without ever prompting**.

Where the recordings live depends on the macOS release, and reaching them may need Full Disk
Access, which has **no key and no dialog** and is granted by hand. `recordings_status`
reports which of the two situations the server is in rather than returning an empty list —
an empty library and an unreadable one must never look the same.

**A linker-signed binary gets no TCC prompt.** `pack.sh` re-signs and prints the designated
requirement; an empty line there means the build is broken in a way nothing else will show.
