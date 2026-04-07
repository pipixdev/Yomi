//
//  SampleLibrary.swift
//  Yomi
//

import Foundation

enum SampleLibrary {
    static let previewBook = BookRecord(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        title: "四畳半神話大系",
        author: "森見登美彦",
        importedAt: .now,
        chapters: [
            BookChapter(
                id: "sample-chapter-1",
                title: "第一章",
                sourceHref: "sample-chapter-1.xhtml",
                paragraphs: [
                    BookParagraph(id: "sample-chapter-1-p0", text: "大学三回生の春までの二年間、実益のあることなど何一つしていないことを断言しておこう。", role: .body),
                    BookParagraph(id: "sample-chapter-1-p1", text: "異性との健全な交際、学問への精進、肉体の鍛錬など、社会的有為の人材となるための布石の数々をことごとくはずし、", role: .body),
                    BookParagraph(id: "sample-chapter-1-p2", text: "異性からの孤立、学問の放棄、肉体の衰弱化などの打たんでもよい布石ばかりを打ち続けてきた。", role: .body)
                ]
            )
        ],
        tableOfContents: [
            BookNavigationPoint(
                id: "sample-nav-1",
                title: "第一章",
                chapterID: "sample-chapter-1",
                paragraphID: "sample-chapter-1-p0",
                children: []
            )
        ],
        epubRelativePath: "debug/sample.epub",
        coverRelativePath: nil,
        readingProgress: ReaderLocation(
            chapterID: "sample-chapter-1",
            paragraphID: "sample-chapter-1-p0",
            updatedAt: .now
        )
    )
}
