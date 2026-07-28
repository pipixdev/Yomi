# Yomi

Yomi is a SwiftUI EPUB reading app designed for Japanese reading workflows.

It currently focuses on a few core experiences:

- Importing EPUB files and plain-text TXT files into a local bookshelf
- Creating simple EPUB books from pasted clipboard text, with each non-empty line becoming one paragraph
- Managing, rebuilding, and removing books from the library
- Opening and reading EPUB content with Readium
- Normalizing imported content to produce more consistent layout and paragraph structure
- Adding ruby / furigana annotations to Japanese text
- Opening paragraph analysis by tapping reading text, with vertical reading, an upward pull at the bottom to advance, a downward pull at the top to return to the previous paragraph, and return-to-paragraph positioning
- Running MeCab-based paragraph token analysis for faster word inspection during reading
- Reading analyzed paragraphs aloud with synchronized word highlighting
- Saving reading location and progress so users can continue later

## Current Project Status

- The app is primarily built with SwiftUI
- Reader integration is based on Readium
- Japanese text analysis is powered by MeCab + IPADic
- The current implementation is iOS-first; some reading features fall back to unavailable states on non-iOS platforms
- App data is mainly stored in the local Application Support directory

## Dependencies

- Readium Swift Toolkit
  - Purpose: EPUB parsing, streaming, navigation, and reader integration
  - Repository: [https://github.com/readium/swift-toolkit](https://github.com/readium/swift-toolkit)
- Mecab-Swift
  - Purpose: Japanese text tokenization
  - Repository: [https://github.com/shinjukunian/Mecab-Swift](https://github.com/shinjukunian/Mecab-Swift)
- IPADic
  - Purpose: Japanese dictionary data used by MeCab
  - Source: included through Mecab-Swift
  - Repository: [https://github.com/shinjukunian/Mecab-Swift](https://github.com/shinjukunian/Mecab-Swift)
