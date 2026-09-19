//
//  ReaderFontOption.swift
//  Yomi
//

import Foundation

enum ReaderFontOption: String, CaseIterable, Identifiable {
    case mincho
    case gothic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mincho:
            return String(localized: "Mincho")
        case .gothic:
            return String(localized: "Gothic")
        }
    }
}
