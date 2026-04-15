# Yomi

## Project Architecture

### Current Shape of the App

- `Yomi` is a SwiftUI reading app centered around importing EPUB files, showing them on a bookshelf, and opening them in a Readium-based reader.
- The project currently has one main app target with UI, local persistence, EPUB normalization, and Japanese text annotation logic living in the same module.
- The architecture is lightweight and feature-oriented rather than deeply layered. Most work starts from the app entry point, the shared store, or one of the main feature views.

### Main Entry Points

- Start at `Yomi/YomiApp.swift`.
  This is the app entry point. It creates the shared `LibraryStore`, injects it with `environmentObject`, and applies the app-wide theme preference.
- Then read `Yomi/ContentView.swift`.
  This is the shell/root navigation. It switches between the bookshelf flow and the settings flow.
- Then read `Yomi/BookshelfView.swift`.
  This is the main user-facing feature screen for importing, listing, opening, rebuilding, and removing books.

### State and Persistence

- `Yomi/LibraryStore.swift` is the central state container.
- `LibraryStore` owns the in-memory library list, import/rebuild progress UI state, import errors, book deletion, and reading progress updates.
- Book metadata is persisted to `library.json` under Application Support.
- Book files are stored under `Application Support/Books/<book-id>/...`.
- `LibraryStore` is the first place to inspect when working on data flow, persistence, import lifecycle, or reader progress behavior.

### Core Models

- `Yomi/Models.swift` defines `BookRecord`, `ReaderToken`, and `ReaderPartOfSpeech`.
- `BookRecord` is the key persisted model. It links the UI, import pipeline, normalized files, cover assets, and reading progress restoration.

### Reader Stack

- `Yomi/ReaderView.swift` is the bridge from SwiftUI into the Readium reader.
- On iOS, `ReaderView` wraps a UIKit `ReadiumReaderViewController` via `UIViewControllerRepresentable`.
- Reader preferences such as theme, font, and page margins are stored with `@AppStorage`.
- Paragraph actions are injected into normalized HTML slots; the toolbar now supports copy, per-paragraph TTS playback, and a paragraph parsing entry point.
- `Yomi/ParagraphAnalysisView.swift` is the native token analysis screen pushed from the reader. It displays MeCab tokenization results for one paragraph and currently provides verb-specific detail cards plus placeholder views for other parts of speech.
- Paragraph TTS playback caches synthesized WAV audio per book, per paragraph, and per active TTS reference configuration so repeated plays can reuse local audio instead of re-requesting the service.
- Rebuilding or removing a book clears that book's paragraph TTS cache so playback stays aligned with the latest normalized content.
- Reader location changes are pushed back into `LibraryStore` so progress can be restored later.

### Preferences and UI Settings

- `Yomi/ReaderPreferencesView.swift` contains the settings UI.
- App appearance and reader preferences are intentionally simple and currently stored in `@AppStorage`, not in a more complex settings domain.
- Paragraph TTS runtime settings persist the service base URL plus a user-managed list of reference presets, where each preset stores one audio sample and one reference text and settings choose which preset is active or `None`.

### EPUB Import and Normalization Pipeline

- `LibraryStore.importBook` and `LibraryStore.rebuildBook` are the main workflow entry points for book processing.
- `Yomi/EPUBImportNormalizer.swift` rewrites imported EPUB content into a reading-optimized version.
- The normalizer removes publisher styling, injects app-controlled reading styles, promotes likely chapter headings, and adds paragraph action slots.
- Normalized output is stored alongside the original EPUB so the app can keep both the source asset and a processed reading version.

### Japanese Text Processing

- `Yomi/JapaneseTextAnalyzer.swift` tokenizes Japanese text with MeCab/IPADic and maps tokens into app-specific reader models.
- `Yomi/JapaneseRubyAnnotationPipeline.swift` annotates HTML content with ruby/furigana-style enhancements and caches transformed documents.
- This pipeline is part of the reading experience, not a separate backend service.

### Localization Expectation

- User-facing strings are localized through `Yomi/Localizable.xcstrings`.
- Any UI change should preserve or extend multilingual support instead of hardcoding new user-facing copy without localization.

### Fast Start for New Conversations

- If you are new to the project, begin in this order:
  1. Read `YomiApp.swift` to understand app bootstrapping.
  2. Read `ContentView.swift` to understand navigation structure.
  3. Read `BookshelfView.swift` to understand the main feature flow.
  4. Read `LibraryStore.swift` to understand state, persistence, and import/rebuild workflows.
  5. Read `ReaderView.swift` if the task touches reading behavior.
  6. Read `EPUBImportNormalizer.swift` and `JapaneseRubyAnnotationPipeline.swift` if the task touches content transformation or Japanese annotation.
