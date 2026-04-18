# Yomi

Yomi is a SwiftUI EPUB reading app designed for Japanese reading workflows.

It currently focuses on a few core experiences:

- Importing EPUB files into a local bookshelf
- Managing, rebuilding, and removing books from the library
- Opening and reading EPUB content with Readium
- Normalizing imported content to produce more consistent layout and paragraph structure
- Adding ruby / furigana annotations to Japanese text
- Running MeCab-based paragraph token analysis for faster word inspection during reading
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