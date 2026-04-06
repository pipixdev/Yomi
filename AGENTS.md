# AGENTS.md

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- For this project, prefer XcodeBuildMCP over raw `xcodebuild`, `simctl`, or ad-hoc simulator commands when building, running, logging, debugging, or driving the UI.
- Default project context for XcodeBuildMCP:
  project path: `/Users/pipix/Documents/Projects/Yomi/Yomi.xcodeproj`
  scheme: `Yomi`
  simulator: `iPhone 17`
  bundle id: `com.pipix.Yomi`

## Testing Priority

- For this project, prefer macOS validation first when using XcodeBuildMCP for build, run, debug, or manual verification.
- After each task is verified on macOS, run the corresponding iOS simulator check before considering the task complete.
- Keep `.xcodebuildmcp/config.yaml` aligned with that priority so the default MCP context stays on macOS unless a task explicitly requires iOS-first work.

## Recommended XcodeBuildMCP Flow

- First verify or establish context with project discovery or the local `.xcodebuildmcp/config.yaml` defaults.
- For the default validation path, use the macOS workflow and keep iOS simulator checks as the follow-up validation step.
- For simulator execution, prefer the single-step `simulator build-and-run` flow instead of manually splitting build, install, and launch.
- For macOS execution, prefer the single-step `macos build-and-run` flow instead of manually splitting build and launch.
- For compile-only validation, use `simulator build`.
- For compile-only validation on macOS, use `macos build`.
- For log collection, use `logging start-simulator-log-capture`, reproduce the behavior, then `logging stop-simulator-log-capture`.
- For UI work, use this order:
  1. `ui-automation screenshot`
  2. `ui-automation snapshot-ui`
  3. `ui-automation tap` by accessibility label or id if available
  4. fall back to coordinate taps only when the accessibility tree is incomplete
  5. capture another screenshot and refreshed UI snapshot to verify the result
- If the app is not foregrounded, use UI automation to tap the `Yomi` icon from the simulator home screen before continuing.
- If simulator-related commands fail inside a restricted sandbox, rerun them with the permissions needed to access `CoreSimulatorService`.

## Project-Specific Notes

- This repository is still the default Xcode template app with minimal UI and no real business logic yet.
- The initial iOS screen is mostly blank and only shows `+` and `Edit` in the navigation bar until items are added.
- The SwiftUI accessibility tree may be sparse on this template. When that happens, use screenshots for visual confirmation and coordinate taps as a fallback.
