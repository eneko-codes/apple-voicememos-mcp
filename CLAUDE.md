# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, delete or move an existing recording — these are critical data.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real recordings, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own recording and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Synthetic audio you generate goes under `$TMPDIR`, never in the owner's library, named `TESTING: ...` and deleted in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) for Voice Memos. Recordings are reached as files on disk (no framework or scripting dictionary exists); transcription uses the on-device `Speech` framework. No network, no cloud API.

## Apple frameworks

[Speech](https://developer.apple.com/documentation/speech) for transcription — `SpeechAnalyzer`, `SpeechTranscriber` and `AssetInventory`, the macOS 26 Swift-only API, with `SFSpeechRecognizer` used only for authorisation. [AVFoundation](https://developer.apple.com/documentation/avfoundation) — `AVURLAsset`, `AVMetadataItem`, `AVAudioFile` — for title, duration and audio. [FileManager](https://developer.apple.com/documentation/foundation/filemanager) walks the library and makes `recording_export`'s copy, the only write. [CryptoKit](https://developer.apple.com/documentation/cryptokit) `SHA256` keys the transcript cache. Consent key: [`NSSpeechRecognitionUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsspeechrecognitionusagedescription).

## Native surface not used

- The Objective-C recognition pipeline: `SFSpeechURLRecognitionRequest`, `SFSpeechRecognitionTask`, `SFSpeechRecognitionResult`, `SFTranscription`, `SFTranscriptionSegment` — so no per-word timings or confidences — plus `SFSpeechLanguageModel` and `SFVoiceAnalytics`.
- All of AVFoundation except asset metadata and file reading: no capture, playback, editing, export, or audio engine.
- Voice Memos itself is not scriptable (`sdef` answers with error -192) and its App Intents hand back no audio, which is why the library is read as files rather than through the app.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-voicememos-mcp | grep -E 'NSSpeechRecognition|NSAppleEvents'
```
