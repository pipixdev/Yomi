# AGENTS.md

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- For this project, prefer XcodeBuildMCP over raw `xcodebuild`, `simctl`, or ad-hoc simulator commands when building, running, logging, debugging, or driving the UI.
- Default project context for XcodeBuildMCP:
  project path: `Yomi.xcodeproj`
  scheme: `Yomi`
  simulator: `iPhone 17`
  bundle id: `com.pipix.Yomi`

## Architecture Maintenance Rule

- `README.md` is the project-facing introduction page and dependency declaration.
- This `AGENTS.md` file is the source of truth for the architecture snapshot and future-LLM project briefing.
- If any task changes the project architecture, feature boundaries, core data flow, persistence approach, reader integration strategy, import/normalization pipeline, or other implementation facts described here, update `AGENTS.md` before considering the task complete.
- If any task changes the product positioning, major user-facing capabilities, supported platform scope, or open-source dependencies, update `README.md` as part of the same task.

## Testing Priority

- For this project, prefer iOS simulator validation first when using XcodeBuildMCP for build, run, debug, or manual verification.
- Unless explicitly requested otherwise, default to iOS checks and do not require macOS-first validation.
- Keep `.xcodebuildmcp/config.yaml` aligned with that priority so the default MCP context stays on iOS unless a task explicitly requires macOS-first work.

## Recommended XcodeBuildMCP Flow

- First verify or establish context with project discovery or the local `.xcodebuildmcp/config.yaml` defaults.
- For the default validation path, use the iOS simulator workflow.
- For simulator execution, prefer the single-step `simulator build-and-run` flow instead of manually splitting build, install, and launch.
- For macOS execution, prefer the single-step `macos build-and-run` flow instead of manually splitting build and launch.
- Unless explicitly requested otherwise, use compile-only validation by default.
- For default compile-only validation, use `simulator build`.
- Use `macos build` only when the task explicitly requires macOS validation.
- For log collection, use `logging start-simulator-log-capture`, reproduce the behavior, then `logging stop-simulator-log-capture`.
- Do not perform screenshot-based verification by default.
- Only when the user explicitly requests screenshot verification, use this UI workflow and continue taking screenshots until the requested behavior is fully verified:
  1. `ui-automation screenshot`
  2. `ui-automation snapshot-ui`
  3. `ui-automation tap` by accessibility label or id if available
  4. fall back to coordinate taps only when the accessibility tree is incomplete
  5. capture another screenshot and refreshed UI snapshot to verify the result
- If the app is not foregrounded, use UI automation to tap the `Yomi` icon from the simulator home screen before continuing.
- If simulator-related commands fail inside a restricted sandbox, rerun them with the permissions needed to access `CoreSimulatorService`.
- During any build/run/test flow, proactively fix warnings and errors discovered in output before considering the task complete.
- For every task, include UI localization adaptation as part of done criteria (at minimum ensure user-facing UI supports multilingual presentation and does not regress existing localized behavior).

## Project Snapshot For Future LLMs

- `Yomi` is a SwiftUI reading app focused on importing EPUB files, displaying them on a bookshelf, and opening them in a Readium-based reader.
- The app is no longer a default Xcode template. The main product surface already includes a bookshelf flow, settings flow, EPUB import/rebuild, normalized reading content, Japanese text analysis, and reader progress persistence.
- The project currently uses one main app target. UI, local persistence, EPUB normalization, reader integration, and Japanese annotation/tokenization logic currently live in the same module.

### Main Entry Points

- Start at `Yomi/YomiApp.swift`. It creates the shared `LibraryStore`, injects it via `environmentObject`, and applies the app-wide theme preference.
- Then read `Yomi/ContentView.swift`. It is the root shell and switches between the bookshelf flow and settings flow.
- Then read `Yomi/BookshelfView.swift`. It is the main user-facing screen for importing, listing, opening, rebuilding, and removing books.

### State And Persistence

- `Yomi/LibraryStore.swift` is the central state container and the first place to inspect for data flow, persistence, import lifecycle, deletion, and reading progress behavior.
- `LibraryStore` persists book metadata to `library.json` under Application Support.
- Book files are stored under `Application Support/Books/<book-id>/...`.
- On launch, `LibraryStore` also scans `Yomi/PreloadedBooks/` and auto-imports missing bundled EPUBs once, deduplicated by source fingerprint.

### Core Models

- `Yomi/Models.swift` defines `BookRecord`, `ReaderToken`, `ReaderPartOfSpeech`, and related reader-facing model types.
- `BookRecord` is the main persisted model linking UI state, imported files, normalized output, cover assets, and reading progress restoration.

### Reader Stack

- `Yomi/ReaderView.swift` bridges SwiftUI into the Readium reader on iOS through `UIViewControllerRepresentable`.
- Reader preferences such as theme, font, parse font size, and page margins are stored with `@AppStorage`.
- Reader location changes are pushed back into `LibraryStore` so progress can be restored later.
- Paragraph actions are injected into normalized HTML and currently support copy, paragraph TTS playback, and opening `ParagraphAnalysisView`.
- `Yomi/ParagraphAnalysisView.swift` shows MeCab tokenization results for one paragraph and opens native iOS dictionary lookup when a token is tapped.
- Readium integration is effectively iOS-first. Non-iOS builds may show fallback unavailable states instead of a working reader.

### EPUB Import And Normalization Pipeline

- `LibraryStore.importBook` and `LibraryStore.rebuildBook` are the main entry points for book processing.
- `Yomi/EPUBImportNormalizer.swift` rewrites imported EPUB content into a reading-optimized version.
- The normalizer removes publisher styling, injects app-controlled reading styles, promotes likely chapter headings, converts Aozora-style `<br>`-delimited text into paragraph blocks when appropriate, and injects paragraph action slots.
- Normalized output is stored alongside the original EPUB so the app keeps both the source asset and the processed reading version.

### Japanese Text Processing

- `Yomi/JapaneseTextAnalyzer.swift` tokenizes Japanese text with MeCab/IPADic and maps tokens into app-specific reader models.
- `Yomi/JapaneseRubyAnnotationPipeline.swift` annotates HTML content with ruby/furigana-style enhancements and caches transformed documents.
- This text-processing pipeline is part of the local reading experience, not a separate backend service.

### Localization And Verification Notes

- User-facing strings should continue to go through `Yomi/Localizable.xcstrings`; do not hardcode new UI copy without localization.
- The SwiftUI accessibility tree can still be sparse in some places. When UI automation cannot rely on accessibility labels alone, use the screenshot-plus-coordinate fallback described above.

### Fast Start For New Conversations

- Read `Yomi/YomiApp.swift` for app bootstrapping.
- Read `Yomi/ContentView.swift` for root navigation.
- Read `Yomi/BookshelfView.swift` for the main feature flow.
- Read `Yomi/LibraryStore.swift` for state, persistence, and import/rebuild workflows.
- Read `Yomi/ReaderView.swift` if the task touches reading behavior.
- Read `Yomi/EPUBImportNormalizer.swift` and `Yomi/JapaneseRubyAnnotationPipeline.swift` if the task touches content transformation or Japanese annotation.
