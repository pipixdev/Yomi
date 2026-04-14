//
//  ParagraphTTSSettings.swift
//  Yomi
//

import Foundation

struct ParagraphTTSSettingsSnapshot {
    let endpointURL: URL?
    let referenceAudioData: Data?
    let referenceText: String?
}

enum ParagraphTTSSettingsStore {
    static let serviceBaseURLKey = "tts.serviceBaseURL"
    static let referenceAudioPathKey = "tts.referenceAudioPath"
    static let referenceTextKey = "tts.referenceText"

    static func snapshot(defaults: UserDefaults = .standard) -> ParagraphTTSSettingsSnapshot {
        let endpoint = endpointURL(defaults: defaults)
        let referenceText = normalizedReferenceText(defaults: defaults)
        let referenceAudio = referenceAudioData(defaults: defaults)
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

    static func saveReferenceAudio(from sourceURL: URL, defaults: UserDefaults = .standard) throws -> URL {
        let fm = FileManager.default
        let directory = try referenceAssetsDirectory(fileManager: fm)
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let destinationURL = directory.appendingPathComponent("reference_audio.\(ext)")

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try fm.copyItem(at: sourceURL, to: destinationURL)
        defaults.set(destinationURL.path, forKey: referenceAudioPathKey)
        return destinationURL
    }

    static func clearReferenceAudio(defaults: UserDefaults = .standard) {
        guard let path = defaults.string(forKey: referenceAudioPathKey), !path.isEmpty else {
            defaults.removeObject(forKey: referenceAudioPathKey)
            return
        }

        let url = URL(filePath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        defaults.removeObject(forKey: referenceAudioPathKey)
    }

    static func saveReferenceText(_ text: String, defaults: UserDefaults = .standard) {
        defaults.set(text, forKey: referenceTextKey)
    }

    static func saveReferenceText(from sourceURL: URL, defaults: UserDefaults = .standard) throws -> String {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(normalized, forKey: referenceTextKey)
        return normalized
    }

    static func referenceAudioPath(defaults: UserDefaults = .standard) -> String? {
        let path = defaults.string(forKey: referenceAudioPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func normalizedReferenceText(defaults: UserDefaults = .standard) -> String? {
        let text = defaults.string(forKey: referenceTextKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func referenceAudioData(defaults: UserDefaults = .standard) -> Data? {
        guard let path = referenceAudioPath(defaults: defaults) else {
            return nil
        }
        return try? Data(contentsOf: URL(filePath: path))
    }

    private static func referenceAssetsDirectory(fileManager: FileManager) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = appSupport.appendingPathComponent("TTSReference", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
