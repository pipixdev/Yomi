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
- After each completed validation cycle, build/install/run the Debug configuration on the connected iPhone X, as requested by the user. Use command-line tools only for build/install/run; do not use Computer Use to operate Xcode. If the MCP CoreDevice inventory/install path omits this iOS 16 device, use `ios-deploy --detect` to find it and `ios-deploy --debug --noninteractive --id <UDID> --bundle <Debug-iphoneos/Yomi.app>` to install and launch the signed Debug build with a retained CLI debug session, preserving app data. Avoid `--justlaunch` on this toolchain: its immediate detach can race process launch; verify a running process instead of trusting the install-complete message. Do not pass `--timeout` to a retained `--noninteractive` session: ios-deploy also treats it as the app runtime limit and terminates the app. Keep the normal simulator compile context intact.
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
- The app's minimum supported iOS version is iOS 16. Newer-system UI effects should remain enabled behind availability checks, with behavior-compatible fallbacks on iOS 16.
- The app is no longer a default Xcode template. The main product surface already includes a bookshelf flow, settings flow, EPUB import/rebuild, normalized reading content, Japanese text analysis, and reader progress persistence.
- The project currently uses one main app target. UI, local persistence, EPUB normalization, reader integration, and Japanese annotation/tokenization logic currently live in the same module.

### Main Entry Points

- Start at `Yomi/YomiApp.swift`. It creates the shared `LibraryStore`, injects it via `environmentObject`, and applies the app-wide theme preference.
- Then read `Yomi/ContentView.swift`. It is the root shell and switches between the bookshelf flow and settings flow.
- Then read `Yomi/BookshelfView.swift`. It is the main user-facing screen for importing, listing, opening, rebuilding, and removing books.

### State And Persistence

- `Yomi/LibraryStore.swift` is the central state container and the first place to inspect for data flow, persistence, import lifecycle, deletion, and reading progress behavior.
- `LibraryStore.importPlainText` creates books from clipboard text or imported TXT files through `Yomi/PlainTextEPUBBuilder.swift`. The builder treats every non-empty input line as one paragraph, packages the result as a minimal EPUB, and feeds it into the same Readium import and normalization path as external EPUB files. TXT imports use the filename as the book title, omit creator metadata so the library shows its localized unknown-author fallback, and decode UTF-8, BOM-marked UTF-16, or Shift JIS text.
- `LibraryStore` persists book metadata to `library.json` under Application Support.
- Book files are stored under `Application Support/Books/<book-id>/...`.
- On launch, `LibraryStore` also scans bundled `PreloadedBooks` resources and auto-imports missing EPUBs once, deduplicated by source fingerprint. The included sample novel is a Debug-only resource; a final target build phase removes it from Release products after resources are copied.

### Core Models

- `Yomi/Models.swift` defines `BookRecord`, `ReaderToken`, `ReaderPartOfSpeech`, and related reader-facing model types.
- `BookRecord` is the main persisted model linking UI state, imported files, normalized output, cover assets, and reading progress restoration.

### Reader Stack

- `Yomi/ReaderView.swift` bridges SwiftUI into the Readium reader on iOS through `UIViewControllerRepresentable`.
- Reader preferences such as theme, font, parse font size, page margins, and optional external-dictionary lookup are stored with `@AppStorage`.
- Reader location changes update `LibraryStore` in memory with duplicate suppression and a single published book mutation. Disk checkpoints are coalesced at one-second intervals; `LibraryManifestWriter` encodes and atomically writes snapshots on a serial utility queue shared with import/rebuild/deletion writes, preserving ordering. Reader dismissal and inactive/background scene transitions flush pending progress with a short UIKit background task. The JSON schema is unchanged. Book cover artwork uses value-based view equality to avoid rereading image files on progress-only updates.
- The main reader keeps the native navigation bar visible with its close/back action, and lays Readium content below the bar. Its internal navigation stack includes a dismissal root beneath the reader so both the back button and the native left-edge swipe close the full-screen reader, while the same gesture pops paragraph analysis back to reading. It does not use a full-screen tap gesture to reveal navigation chrome, avoiding conflicts with tap-to-analyze paragraphs.
- Reader loading is cancellable on teardown, and WebKit script message handlers use a weak forwarding proxy so the navigator does not retain its owning reader.
- Bookshelf and bookmark selection immediately guard against repeated selection and disable their presenting navigation stack. Both entry and exit selection transactions disable the outer modal animation. After a completed native back transition, `ReaderView.onClose` directly clears the owning bookshelf/bookmark selection in that transaction, restoring source interaction with the same state update instead of waiting for an environment dismissal to write the binding back. A cancelled edge swipe never invokes this close callback. The selection transaction disables entry animation, presenting the lightweight, dismissible reader shell directly, with no separate source-screen spinner. Presentation is attached outside the source interaction/accessibility modifiers so reader navigation remains usable. The reader starts its one-shot load only in the first `viewDidAppear`, lazily creates its runtime, and uses `EPUBParser` directly. Readium’s `EPUBSpreadView` owns the only visible loading indicator; the app does not create a full-screen spinner/overlay before it. The brief publication-opening stage shows the same reader shell/background with its back action, then embeds Readium directly. Navigator content interaction and accessibility remain gated until the first settled `locationDidChange`; the native back action remains available. Initial chapter resource failures replace loading with an error. Returning from analysis does not reopen the publication.
- The paragraph bridge caches chapter entries and selectors, invalidates them on DOM child-list changes, and computes sibling positions once per parent. Native bookmark locator JSON is generated lazily for the currently displayed paragraph.
- The normalizer injects hidden paragraph metadata slots into HTML. The reader script binds the preceding paragraph body as a single-tap target, hides any legacy action toolbar UI, and opens `ParagraphAnalysisView` with the current chapter's paragraph list and selected index. The analysis view reports paragraph-index changes back to the reader; when the user returns, the injected script scrolls the loaded Readium resource to that paragraph's paginated position.
- `Yomi/SpeechPlaybackController.swift` owns speech playback state for the paragraph analysis UI. System speech highlights ranges through `AVSpeechSynthesizerDelegate`; Edge speech uses returned word-boundary timestamps to synchronize highlighting with `AVAudioPlayer`.
- Paragraph-analysis TTS uses `AVSpeechSynthesizer` by default. For local testing, `Yomi/EdgeTTSClient.swift` can directly use the same Microsoft Edge consumer WebSocket service as `rany2/edge-tts`; its setting is disabled by default, and network or protocol failures fall back to the system voice. Successful Edge TTS responses and their word-boundary timelines are stored as paired MP3 and JSON files under the app's caches directory using a versioned hash of the voice, output format, and paragraph text, so repeated playback avoids another network request while preserving highlights.
- `ParagraphTokenizationService` confines lazy MeCab initialization, tokenization, and `AnalysisTokenMarkup` ruby/HTML generation to a background actor. Tokens and markup share an eviction budget capped at 16 paragraphs / 12,000 tokens (individual input capped at 256 KB for caching). Ruby alignment is computed once per token. Cancelled and superseded work is rejected.
- `Yomi/ParagraphAnalysisView.swift` uses one native-scrolling `WKWebView` for continuous up/down analysis within the current chapter; the old edge-pull paragraph-switch gesture and nested scroll container are removed. `AnalysisDocumentBuilder` serializes the chapter and loads bundled `AnalysisReader.html` / `AnalysisReader.js` off the main actor. The script keeps lightweight estimated/measured spacers for the chapter, hydrates the visible region plus six neighboring paragraphs on each side (hard cap 33 live rows), and discards offscreen token DOM/native row state. Each window generation cancels obsolete work and rejects late results. Initial positioning pins the tapped paragraph 16 CSS px below the viewport top until user interaction. Mutation batches, document ResizeObserver notifications, and viewport changes restore that explicit anchor; a trailing viewport-sized padding allowance lets the final short paragraph align at the top too. Touch/wheel/scroll keys and native drag/scroll-to-top release the pin. SwiftUI owns the navigation safe area, with automatic WKWebView scroll inset adjustment disabled. Subsequent top-visible-paragraph tracking preserves the existing reader-return locator indices.
- Each analyzed paragraph has its own bookmark, translation, and play/stop buttons directly below its source text, right-aligned with a 4 CSS px gap and unchanged 44×44 CSS px touch targets, with localized accessibility labels and toggle state. Bookmark toggles persist through `LibraryStore`. Translation toggles cancel pending work or hide the result; explicit hidden/shown preferences survive row eviction for the current analysis session. One shared `SpeechPlaybackController` ensures only one paragraph speaks; leaving its live window or closing analysis stops playback. Speech highlighting goes straight to the current paragraph's cached DOM token index using binary search and class deltas, without SwiftUI updates or HTML regeneration. Tapping a token retains the native iOS dictionary and optional external URL-scheme dictionary fallback.
- Layout updates are batched once per animation frame, and changes above the viewport compensate against the first visible paragraph's screen position. Translations participate in the same document flow, so showing/hiding them requires no nested WebView height measurement or SwiftUI layout feedback loop. Scroll position lookup uses binary search over ordered paragraph offsets; only paragraph changes reach SwiftUI.
- `Yomi/BingTranslateClient.swift` first uses a short-lived anonymous Edge consumer token and automatically falls back to an anonymous Bing Translator website session when the consumer endpoint is rate-limited. Successful translations retain the existing versioned disk cache keyed and validated by target language plus source lines. `TranslationMemoryCache` bounds the shared in-memory cache to 128 entries / 1 MiB of UTF-8 translated text; eviction does not remove disk results. Visible/preloaded paragraphs restore cached translations unless explicitly hidden during this session. The analysis view renders one translated result per source line beneath the paragraph's controls. The consumer endpoints remain isolated because they are not a supported public API.
- Readium integration is effectively iOS-first. Non-iOS builds may show fallback unavailable states instead of a working reader.

### EPUB Import And Normalization Pipeline

- `LibraryStore.importBook` and `LibraryStore.rebuildBook` are the main entry points for book processing.
- `LibraryStore.importPlainText` is the text-book entry point. It creates a temporary standards-compliant EPUB locally, then reuses the regular import pipeline so generated books have the same storage, normalization, analysis, and reader behavior.
- `Yomi/EPUBImportNormalizer.swift` rewrites imported EPUB content into a reading-optimized version.
- The normalizer removes publisher styling, injects app-controlled reading styles, promotes likely chapter headings, converts Aozora-style `<br>`-delimited text into paragraph blocks when appropriate, and injects hidden paragraph metadata slots used for tap-to-analyze navigation.
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

- Whole-book translation is started/cancelled from the cover menu and owned by `LibraryStore`, independently of view lifetime. `BookTranslationProgress.swift` extracts the normalized HTML paragraph metadata off the main actor; requests use a bounded rolling task group (per-book concurrency saved in settings, default 60, range 1–120), share the paragraph-analysis source-line preparation and Bing disk cache, and retain successful results when individual paragraphs fail. Authentication and website configuration refreshes are coalesced across concurrent requests. Settings changes apply to newly started tasks. Retrying skips cached paragraphs. Deletion, rebuilding, or reimporting cancels the job. Progress is session-only; iOS suspension can pause execution, and relaunch requires starting again to resume from cached results.

- Paragraph analysis supports toggling paragraph bookmarks. `LibraryStore` atomically persists `ParagraphBookmark` records in Application Support `bookmarks.json`; deleting a book removes its bookmarks. Each bookmark stores the book ID, paragraph excerpt, and a Readium locator with the resource href, DOM CSS selector, and text highlight. `BookmarksView` is available in the root sidebar and the compact bookshelf toolbar; selecting a bookmark opens `ReaderView` with that locator instead of the last reading location.

- Reader performance regression checks live in `Tests/reader-script-checks.mjs`, `Tests/analysis-scroll-checks.mjs`, `Tests/TranslationMemoryCacheChecks.swift`, and `Tests/ReaderPersistenceChecks.swift`; see `docs/reader-performance.md` for commands, scope, and remaining profiling needs.
