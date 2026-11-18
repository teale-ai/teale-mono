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

### Before Making Changes
- Read the file before editing it. Understand existing code before modifying.
- Put decisions and context in the PR description or commit messages, not in session transcripts.
- Run `swift build` to confirm the project compiles before starting.

### Code Quality
- This is a Swift Package Manager project with 25 targets (module table in [TEALE.md](TEALE.md)). Respect module boundaries — don't add cross-module imports without good reason.
- `InferenceProvider` is the core protocol abstraction. New inference backends should conform to it.
- All inter-node messages are length-prefixed JSON over persistent TCP connections. Follow this pattern for new network protocols.
- Keep SwiftUI views in the app targets (`Teale` in `Sources/InferencePoolApp`, `TealeCompanion`), not in library modules. The macOS window UI is the shared web bundle in `Sources/InferencePoolApp/Resources/DesktopCompanionWeb/` (also embedded by the Windows/Linux tray).

### Testing
- Tests require Xcode SDK (XCTest not available with Command Line Tools only).
- SwiftPM can't compile Metal shaders — use Xcode for full builds when Metal is involved.

## Conductor Setup

If you use Conductor for this workspace, set the workspace setup script to:

```bash
./scripts/conductor-setup.sh
```
