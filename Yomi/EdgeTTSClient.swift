import CryptoKit
import Foundation

struct SpeechBoundary: Codable, Hashable, Sendable {
    let text: String
    let offset: TimeInterval
    let duration: TimeInterval
}

struct EdgeTTSSynthesis: Sendable {
    let audio: Data
    let boundaries: [SpeechBoundary]
}

enum EdgeTTSClient {
    static let enabledDefaultsKey = "reader.edgeTTS.enabled"

    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let voice = "ja-JP-NanamiNeural"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    private static let cacheVersion = "2"
    private static let maximumTextBytes = 4_000
    private static let audioCache = EdgeTTSAudioCache()

    enum ClientError: LocalizedError {
        case invalidEndpoint
        case malformedAudioFrame
        case noAudioReceived
        case unexpectedMessage

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "The Edge TTS endpoint could not be created."
            case .malformedAudioFrame:
                return "Edge TTS returned a malformed audio frame."
            case .noAudioReceived:
                return "Edge TTS returned no audio."
            case .unexpectedMessage:
                return "Edge TTS returned an unexpected message."
            }
        }
    }

    static func synthesize(_ text: String) async throws -> EdgeTTSSynthesis {
        let cacheKey = cacheKey(for: text)
        if let cachedSynthesis = await audioCache.synthesis(for: cacheKey) {
#if DEBUG
            print("Yomi Edge TTS cache hit: \(cacheKey)")
#endif
            return cachedSynthesis
        }

        var audio = Data()
        var boundaries: [SpeechBoundary] = []

        for chunk in escapedTextChunks(text) {
            try Task.checkCancellation()
            let result = try await synthesizeChunk(chunk)
            let chunkOffset = Double(audio.count * 8) / 48_000
            audio.append(result.audio)
            boundaries.append(contentsOf: result.boundaries.map {
                SpeechBoundary(
                    text: $0.text,
                    offset: $0.offset + chunkOffset,
                    duration: $0.duration
                )
            })
        }

        guard !audio.isEmpty else {
            throw ClientError.noAudioReceived
        }

        let synthesis = EdgeTTSSynthesis(audio: audio, boundaries: boundaries)
        await audioCache.store(synthesis, for: cacheKey)
        return synthesis
    }

    private static func synthesizeChunk(_ escapedText: String) async throws -> EdgeTTSSynthesis {
        guard let endpoint = makeEndpointURL() else {
            throw ClientError.invalidEndpoint
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: endpoint)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(
            "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            forHTTPHeaderField: "Origin"
        )
        request.setValue("muid=\(randomHex(byteCount: 16));", forHTTPHeaderField: "Cookie")

        let socket = session.webSocketTask(with: request)
        socket.resume()

        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await socket.send(.string(speechConfigurationMessage))
        try await socket.send(.string(ssmlMessage(for: escapedText)))

        var audio = Data()
        var boundaries: [SpeechBoundary] = []
        var didFinish = false

        while !didFinish {
            try Task.checkCancellation()

            switch try await socket.receive() {
            case let .string(message):
                if message.contains("Path:turn.end") {
                    didFinish = true
                } else if message.contains("Path:audio.metadata") {
                    boundaries.append(contentsOf: parseBoundaries(from: message))
                } else if message.contains("Path:response")
                    || message.contains("Path:turn.start")
                {
                    continue
                } else {
                    throw ClientError.unexpectedMessage
                }

            case let .data(message):
                guard message.count >= 2 else {
                    throw ClientError.malformedAudioFrame
                }

                let headerLength = (Int(message[message.startIndex]) << 8)
                    | Int(message[message.index(after: message.startIndex)])
                let audioStart = 2 + headerLength
                guard audioStart <= message.count else {
                    throw ClientError.malformedAudioFrame
                }

                if audioStart < message.count {
                    audio.append(message.subdata(in: audioStart ..< message.count))
                }

            @unknown default:
                throw ClientError.unexpectedMessage
            }
        }

        guard !audio.isEmpty else {
            throw ClientError.noAudioReceived
        }
        return EdgeTTSSynthesis(audio: audio, boundaries: boundaries)
    }

    private static func makeEndpointURL() -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "speech.platform.bing.com"
        components.path = "/consumer/speech/synthesize/readaloud/edge/v1"
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionID()),
            URLQueryItem(name: "Sec-MS-GEC", value: securityToken()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumVersion)")
        ]
        return components.url
    }

    private static var speechConfigurationMessage: String {
        """
        X-Timestamp:\(edgeTimestamp())\r
        Content-Type:application/json; charset=utf-8\r
        Path:speech.config\r
        \r
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"\(outputFormat)"}}}}\r

        """
    }

    private static func ssmlMessage(for escapedText: String) -> String {
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='ja-JP'><voice name='\(voice)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escapedText)</prosody></voice></speak>
        """

        return """
        X-RequestId:\(connectionID())\r
        Content-Type:application/ssml+xml\r
        X-Timestamp:\(edgeTimestamp())Z\r
        Path:ssml\r
        \r
        \(ssml)
        """
    }

    private static func escapedTextChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentByteCount = 0

        for character in text {
            let escaped = escapeXML(String(character))
            let byteCount = escaped.utf8.count

            if currentByteCount + byteCount > maximumTextBytes, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentByteCount = 0
            }

            current += escaped
            currentByteCount += byteCount
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func edgeTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func securityToken() -> String {
        let windowsEpochOffset = 11_644_473_600.0
        let interval = Date().timeIntervalSince1970 + windowsEpochOffset
        let roundedInterval = interval - interval.truncatingRemainder(dividingBy: 300)
        let ticks = roundedInterval * 10_000_000
        let value = String(format: "%.0f", ticks) + trustedClientToken
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private static func parseBoundaries(from message: String) -> [SpeechBoundary] {
        guard
            let separator = message.range(of: "\r\n\r\n"),
            let payload = message[separator.upperBound...].data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let metadata = root["Metadata"] as? [[String: Any]]
        else {
            return []
        }

        return metadata.compactMap { item in
            guard
                item["Type"] as? String == "WordBoundary",
                let data = item["Data"] as? [String: Any],
                let offset = data["Offset"] as? NSNumber,
                let duration = data["Duration"] as? NSNumber,
                let textContainer = data["text"] as? [String: Any],
                let text = textContainer["Text"] as? String
            else {
                return nil
            }

            return SpeechBoundary(
                text: unescapeXML(text),
                offset: offset.doubleValue / 10_000_000,
                duration: duration.doubleValue / 10_000_000
            )
        }
    }

    private static func unescapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func cacheKey(for text: String) -> String {
        let identity = [
            "edge-tts-cache-\(cacheVersion)",
            voice,
            outputFormat,
            text
        ].joined(separator: "\n")

        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static var userAgent: String {
        let majorVersion = chromiumVersion.split(separator: ".").first ?? "143"
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(majorVersion).0.0.0 Safari/537.36 Edg/\(majorVersion).0.0.0"
    }

    private static func connectionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func randomHex(byteCount: Int) -> String {
        (0 ..< byteCount)
            .map { _ in String(format: "%02X", UInt8.random(in: .min ... .max)) }
            .joined()
    }
}

private actor EdgeTTSAudioCache {
    private let directoryURL: URL?

    init() {
        directoryURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("EdgeTTS", isDirectory: true)
    }

    func synthesis(for key: String) -> EdgeTTSSynthesis? {
        guard
            let audioURL = audioURL(for: key),
            let metadataURL = metadataURL(for: key),
            let audio = try? Data(contentsOf: audioURL),
            !audio.isEmpty,
            let metadata = try? Data(contentsOf: metadataURL),
            let boundaries = try? JSONDecoder().decode([SpeechBoundary].self, from: metadata)
        else {
            removeFiles(for: key)
            return nil
        }
        return EdgeTTSSynthesis(audio: audio, boundaries: boundaries)
    }

    func store(_ synthesis: EdgeTTSSynthesis, for key: String) {
        guard
            !synthesis.audio.isEmpty,
            let directoryURL,
            let audioURL = audioURL(for: key),
            let metadataURL = metadataURL(for: key)
        else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let metadata = try JSONEncoder().encode(synthesis.boundaries)
            try synthesis.audio.write(to: audioURL, options: .atomic)
            try metadata.write(to: metadataURL, options: .atomic)
        } catch {
            print("Yomi Edge TTS cache write failed: \(error)")
        }
    }

    private func audioURL(for key: String) -> URL? {
        directoryURL?.appendingPathComponent(key).appendingPathExtension("mp3")
    }

    private func metadataURL(for key: String) -> URL? {
        directoryURL?.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func removeFiles(for key: String) {
        if let audioURL = audioURL(for: key) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        if let metadataURL = metadataURL(for: key) {
            try? FileManager.default.removeItem(at: metadataURL)
        }
    }
}
