# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — DO NOT MODIFY OR REMOVE ANY ORIGINAL RECORDING

**It is FORBIDDEN to modify, delete or move any recording the owner made. These recordings are critical data that cannot be lost!**
This rule outranks every other instruction in this file. It applies to every agent and every
session.

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

- **Recognition is on-device by construction.** `SpeechAnalyzer`/`SpeechTranscriber`
  (macOS 26, replacing `SFSpeechRecognizer`) have no server-backed path at all — there is no
  flag to set or unset, unlike the old API. That is not a preference and must not become
  configurable: the whole reason this is acceptable at all is that a private recording stays
  private. The tool description says so, and it must keep saying so.
- **A locale's on-device model downloads on first use, not through Dictation.** Verified by
  hand: enabling a language in System Settings → Keyboard → Dictation does not install this
  framework's model — it is a separate asset. `TranscriptionEngine.ensureInstalled` calls
  `AssetInventory.assetInstallationRequest` itself rather than sending the owner to a
  settings pane that would not help.
- **`maximumTranscribeCount` bounds a batch anyway**, even though on-device recognition now
  runs well faster than real time once a model is installed: a sweep of a whole library
  would still return a wall of text nobody asked for, and a first-time model download is
  still a real wait.
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
