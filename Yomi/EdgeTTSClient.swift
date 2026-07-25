import CryptoKit
import Foundation

enum EdgeTTSClient {
    static let enabledDefaultsKey = "reader.edgeTTS.enabled"

    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let voice = "ja-JP-NanamiNeural"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    private static let cacheVersion = "1"
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

    static func synthesize(_ text: String) async throws -> Data {
        let cacheKey = cacheKey(for: text)
        if let cachedAudio = await audioCache.data(for: cacheKey) {
#if DEBUG
            print("Yomi Edge TTS cache hit: \(cacheKey)")
#endif
            return cachedAudio
        }

        var result = Data()

        for chunk in escapedTextChunks(text) {
            try Task.checkCancellation()
            result.append(try await synthesizeChunk(chunk))
        }

        guard !result.isEmpty else {
            throw ClientError.noAudioReceived
        }

        await audioCache.store(result, for: cacheKey)
        return result
    }

    private static func synthesizeChunk(_ escapedText: String) async throws -> Data {
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
        var didFinish = false

        while !didFinish {
            try Task.checkCancellation()

            switch try await socket.receive() {
            case let .string(message):
                if message.contains("Path:turn.end") {
                    didFinish = true
                } else if message.contains("Path:response")
                    || message.contains("Path:turn.start")
                    || message.contains("Path:audio.metadata")
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
        return audio
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
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"\(outputFormat)"}}}}\r

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

    func data(for key: String) -> Data? {
        guard let fileURL = fileURL(for: key) else { return nil }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return data
    }

    func store(_ data: Data, for key: String) {
        guard !data.isEmpty, let directoryURL, let fileURL = fileURL(for: key) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Yomi Edge TTS cache write failed: \(error)")
        }
    }

    private func fileURL(for key: String) -> URL? {
        directoryURL?.appendingPathComponent(key).appendingPathExtension("mp3")
    }
}
