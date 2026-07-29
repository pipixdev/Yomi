//
//  DictionaryLookupPreferences.swift
//  Yomi
//

import Foundation

enum DictionaryLookupPreferences {
    static let externalLookupEnabledKey = "analysis.externalDictionary.enabled"
    static let externalLookupURLTemplateKey = "analysis.externalDictionary.urlTemplate"

    static func externalLookupURL(for term: String, template: String) -> URL? {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else { return nil }

        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "#&+=?")
        guard let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }

        let resolvedTemplate: String
        if trimmedTemplate.contains("{term}") {
            resolvedTemplate = trimmedTemplate.replacingOccurrences(of: "{term}", with: encodedTerm)
        } else if trimmedTemplate.contains("搜索内容") {
            resolvedTemplate = trimmedTemplate.replacingOccurrences(of: "搜索内容", with: encodedTerm)
        } else {
            return nil
        }

        guard
            let url = URL(string: resolvedTemplate),
            url.scheme?.isEmpty == false
        else {
            return nil
        }
        return url
    }
}
