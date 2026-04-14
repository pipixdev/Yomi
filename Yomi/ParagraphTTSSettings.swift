//
//  ParagraphTTSSettings.swift
//  Yomi
//

import Foundation
import CryptoKit

struct ParagraphTTSReference: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var audioPath: String?
    var text: String

    init(id: String = UUID().uuidString, title: String = "", audioPath: String? = nil, text: String = "") {
        self.id = id
        self.title = title
        self.audioPath = audioPath
        self.text = text
    }

    var normalizedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ParagraphTTSSettingsSnapshot {
    let endpointURL: URL?
    let referenceAudioData: Data?
    let referenceText: String?
}

enum ParagraphTTSSettingsStore {
    static let serviceBaseURLKey = "tts.serviceBaseURL"
    static let referencesKey = "tts.references"
    static let selectedReferenceIDKey = "tts.selectedReferenceID"

    static func snapshot(defaults: UserDefaults = .standard) -> ParagraphTTSSettingsSnapshot {
        let endpoint = endpointURL(defaults: defaults)
        let reference = selectedReference(defaults: defaults)
        let referenceText = reference?.normalizedText
        let referenceAudio = reference.flatMap { reference in
            referenceAudioData(for: reference)
        }
        return ParagraphTTSSettingsSnapshot(
            endpointURL: endpoint,
            referenceAudioData: referenceAudio,
            referenceText: referenceText
        )
    }

    static func endpointURL(defaults: UserDefaults = .standard) -> URL? {
        let raw = defaults.string(forKey: serviceBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return nil
        }

        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        guard let baseURL = URL(string: normalized) else {
            return nil
        }
        return baseURL.appending(path: "v1/tts")
    }

    static func references(defaults: UserDefaults = .standard) -> [ParagraphTTSReference] {
        guard let data = defaults.data(forKey: referencesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([ParagraphTTSReference].self, from: data)
        } catch {
            return []
        }
    }

    static func saveReferences(_ references: [ParagraphTTSReference], defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(references)
            defaults.set(data, forKey: referencesKey)
        } catch {
            return
        }

        let selectedID = selectedReferenceID(defaults: defaults)
        if let selectedID, !references.contains(where: { $0.id == selectedID }) {
            defaults.removeObject(forKey: selectedReferenceIDKey)
        }
    }

    static func selectedReferenceID(defaults: UserDefaults = .standard) -> String? {
        let id = defaults.string(forKey: selectedReferenceIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty else {
            return nil
        }
        return id
    }

    static func setSelectedReferenceID(_ id: String?, defaults: UserDefaults = .standard) {
        guard
            let id = id?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
        else {
            defaults.removeObject(forKey: selectedReferenceIDKey)
            return
        }

        defaults.set(id, forKey: selectedReferenceIDKey)
    }

    static func selectedReference(defaults: UserDefaults = .standard) -> ParagraphTTSReference? {
        guard let selectedID = selectedReferenceID(defaults: defaults) else {
            return nil
        }
        return references(defaults: defaults).first(where: { $0.id == selectedID })
    }

    static func importReferenceAudio(
        from sourceURL: URL,
        for referenceID: String
    ) throws -> URL {
        let fm = FileManager.default
        let directory = try referenceDirectory(for: referenceID, fileManager: fm)
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let destinationURL = directory.appendingPathComponent("reference_audio.\(ext)")

        for existingURL in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try? fm.removeItem(at: existingURL)
        }

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try fm.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    static func deleteReference(_ referenceID: String, defaults: UserDefaults = .standard) {
        var allReferences = references(defaults: defaults)
        guard let index = allReferences.firstIndex(where: { $0.id == referenceID }) else {
            return
        }

        removeReferenceAssets(for: allReferences[index], fileManager: .default)
        allReferences.remove(at: index)
        saveReferences(allReferences, defaults: defaults)
    }

    static func cachedAudio(forText text: String, bookID: UUID, settings: ParagraphTTSSettingsSnapshot) -> Data? {
        guard let fileURL = cacheFileURL(forText: text, bookID: bookID, settings: settings) else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    static func cacheAudio(_ audioData: Data, forText text: String, bookID: UUID, settings: ParagraphTTSSettingsSnapshot) {
        guard let fileURL = cacheFileURL(forText: text, bookID: bookID, settings: settings) else {
            return
        }

        do {
            try audioData.write(to: fileURL, options: .atomic)
        } catch {
            // Cache misses are acceptable; playback should continue even if persistence fails.
        }
    }

    static func clearCachedAudio(forBookID bookID: UUID) {
        let fm = FileManager.default
        guard let directory = bookCacheDirectory(for: bookID, fileManager: fm) else {
            return
        }

        if fm.fileExists(atPath: directory.path) {
            try? fm.removeItem(at: directory)
        }
    }

    private static func referenceAudioData(for reference: ParagraphTTSReference) -> Data? {
        guard
            let path = reference.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return nil
        }
        return try? Data(contentsOf: URL(filePath: path))
    }

    private static func removeReferenceAssets(for reference: ParagraphTTSReference, fileManager: FileManager) {
        guard
            let path = reference.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return
        }

        let fileURL = URL(filePath: path)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    private static func referenceAssetsRootDirectory(fileManager: FileManager) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = appSupport.appendingPathComponent("TTSReferences", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func referenceDirectory(for referenceID: String, fileManager: FileManager) throws -> URL {
        let root = try referenceAssetsRootDirectory(fileManager: fileManager)
        let directory = root.appendingPathComponent(referenceID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func cacheFileURL(forText text: String, bookID: UUID, settings: ParagraphTTSSettingsSnapshot) -> URL? {
        let fm = FileManager.default
        guard let directory = bookCacheDirectory(for: bookID, fileManager: fm) else {
            return nil
        }

        let cacheKey = cacheKey(forText: text, settings: settings)
        return directory.appendingPathComponent("\(cacheKey).wav")
    }

    private static func cacheKey(forText text: String, settings: ParagraphTTSSettingsSnapshot) -> String {
        let endpoint = settings.endpointURL?.absoluteString ?? ""
        let referenceText = settings.referenceText ?? ""
        let referenceAudioHash = sha256Hex(for: settings.referenceAudioData ?? Data())
        return sha256Hex(for: Data("\(endpoint)\n\(referenceText)\n\(referenceAudioHash)\n\(text)".utf8))
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func ttsCacheDirectory(fileManager: FileManager) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = appSupport.appendingPathComponent("TTSAudioCache", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func bookCacheDirectory(for bookID: UUID, fileManager: FileManager) -> URL? {
        guard let root = try? ttsCacheDirectory(fileManager: fileManager) else {
            return nil
        }

        let directory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }
}
