# Teale — Claude Code Instructions

## Project Reference

See [TEALE.md](TEALE.md) for full project overview: phases, architecture, modules, dependencies, and build notes.

## Building

```bash
swift build          # CLI build (~104s, both macOS + iOS targets)
# Open Package.swift in Xcode for full app experience (MenuBarExtra needs app bundle)
```

Always verify `swift build` succeeds before finishing work.

## Workflow Rules

### Branch Discipline
- **Merge your branch when work is done.** Do not leave feature branches dangling — merge into `main` and delete the branch before ending the session.
- If the merge has conflicts, resolve them and verify `swift build` still passes after resolution.
- Delete remote branches after merging (`git push origin --delete <branch>`).

### Session Logging
- **At the end of every session**, create or update a chat log in `chats/YYYY-MM-DD.md` summarizing what was done, key decisions, and issues encountered.
- If multiple sessions happen on the same day, append to the existing file.
- Session notes live in `chats/` as markdown files named by date (e.g. `chats/2026-04-05.md`). Read these for context on decisions made in prior sessions.

### Before Making Changes
- Read the file before editing it. Understand existing code before modifying.
- Check `chats/` for recent session context if picking up ongoing work.
- Run `swift build` to confirm the project compiles before starting.

### Code Quality
- This is a Swift Package Manager project with 13 modules. Respect module boundaries — don't add cross-module imports without good reason.
- `InferenceProvider` is the core protocol abstraction. New inference backends should conform to it.
- All inter-node messages are length-prefixed JSON over persistent TCP connections. Follow this pattern for new network protocols.
- Keep SwiftUI views in the app targets (`InferencePoolApp`, `TealeCompanion`), not in library modules.

### Testing
- Tests require Xcode SDK (XCTest not available with Command Line Tools only).
- SwiftPM can't compile Metal shaders — use Xcode for full builds when Metal is involved.

## Conductor Setup

If you use Conductor for this workspace, set the workspace setup script to:

```bash
./scripts/conductor-setup.sh
```
