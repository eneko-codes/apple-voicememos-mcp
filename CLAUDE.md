# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not modify, delete, or move an existing recording — these are critical data. Test recordings (synthetic audio the agent generates itself) may be created under `$TMPDIR` and must be clearly named `TESTING: ...`, deleted when done.

## What this is

A local MCP server (Swift 6, stdio transport) for Voice Memos. Recordings are reached as files on disk (no framework or scripting dictionary exists); transcription uses the on-device `Speech` framework. No network, no cloud API.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-voicememos-mcp | grep -E 'NSSpeechRecognition|NSAppleEvents'
```
