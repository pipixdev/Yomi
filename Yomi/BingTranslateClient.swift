//
//  BingTranslateClient.swift
//  Yomi
//

import CryptoKit
import Foundation

enum BingTranslateClient {
    private static let service = BingTranslateService()

    static func translate(
        _ lines: [String],
        targetLanguage: String
    ) async throws -> [String] {
        try await service.translate(lines, targetLanguage: targetLanguage)
    }

    static func cachedTranslation(
        for lines: [String],
        targetLanguage: String
    ) async -> [String]? {
        await service.cachedTranslation(
            for: lines,
            targetLanguage: targetLanguage
        )
    }

    static func preferredTargetLanguage() -> String {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        return preferredLanguage.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    }
}

private actor BingTranslateService {
    private let authenticationURL = URL(string: "https://edge.microsoft.com/translate/auth")!
    private let translationURL = URL(string: "https://api.cognitive.microsofttranslator.com/translate")!
    private let websiteURL = URL(string: "https://www.bing.com/translator")!
    private let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    private let websiteSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private var accessToken: String?
    private var accessTokenExpiration = Date.distantPast
    private var websiteConfiguration: WebsiteConfiguration?
    private let translationCacheDirectoryURL = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    ).first?
        .appendingPathComponent("Translations", isDirectory: true)
        .appendingPathComponent("v1", isDirectory: true)
    private var translations: [String: [String]] = [:]

    enum ClientError: Error {
        case invalidResponse
        case requestFailed(statusCode: Int)
        case emptyTranslation
    }

    func translate(
        _ lines: [String],
        targetLanguage: String
    ) async throws -> [String] {
        guard !lines.isEmpty else { return [] }

#if DEBUG
        print(
            "Yomi Bing Translate request: \(lines.count) line(s), "
                + "\(lines.reduce(0) { $0 + $1.count }) character(s), "
                + "target \(targetLanguage)"
        )
#endif

        let cacheKey = translationCacheKey(
            for: lines,
            targetLanguage: targetLanguage
        )
        if let cachedTranslation = cachedTranslation(
            for: lines,
            targetLanguage: targetLanguage,
            cacheKey: cacheKey
        ) {
            return cachedTranslation
        }

        let result: [String]
        do {
            do {
                result = try await requestTranslation(
                    lines,
                    targetLanguage: targetLanguage,
                    accessToken: try await validAccessToken()
                )
            } catch ClientError.requestFailed(statusCode: 401) {
                accessToken = nil
                accessTokenExpiration = .distantPast
                result = try await requestTranslation(
                    lines,
                    targetLanguage: targetLanguage,
                    accessToken: try await validAccessToken()
                )
            }
        } catch {
#if DEBUG
            print("Yomi Bing Translate switching to website fallback: \(error)")
#endif
            result = try await requestWebsiteTranslation(
                lines,
                targetLanguage: targetLanguage
            )
        }
        translations[cacheKey] = result
        persistTranslation(
            result,
            sourceLines: lines,
            targetLanguage: targetLanguage,
            cacheKey: cacheKey
        )
        return result
    }

    func cachedTranslation(
        for lines: [String],
        targetLanguage: String
    ) -> [String]? {
        guard !lines.isEmpty else { return nil }
        return cachedTranslation(
            for: lines,
            targetLanguage: targetLanguage,
            cacheKey: translationCacheKey(
                for: lines,
                targetLanguage: targetLanguage
            )
        )
    }

    private func cachedTranslation(
        for lines: [String],
        targetLanguage: String,
        cacheKey: String
    ) -> [String]? {
        if let cachedTranslation = translations[cacheKey] {
            return cachedTranslation
        }

        guard
            let cacheURL = translationCacheURL(for: cacheKey),
            let data = try? Data(contentsOf: cacheURL),
            let record = try? JSONDecoder().decode(
                TranslationCacheRecord.self,
                from: data
            ),
            record.sourceLines == lines,
            record.targetLanguage == targetLanguage,
            record.translatedLines.count == lines.count,
            record.translatedLines.allSatisfy({ !$0.isEmpty })
        else {
            return nil
        }

        translations[cacheKey] = record.translatedLines
        return record.translatedLines
    }

    private func persistTranslation(
        _ translatedLines: [String],
        sourceLines: [String],
        targetLanguage: String,
        cacheKey: String
    ) {
        guard
            let translationCacheDirectoryURL,
            let cacheURL = translationCacheURL(for: cacheKey)
        else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: translationCacheDirectoryURL,
                withIntermediateDirectories: true
            )
            let record = TranslationCacheRecord(
                sourceLines: sourceLines,
                targetLanguage: targetLanguage,
                translatedLines: translatedLines
            )
            try JSONEncoder().encode(record).write(to: cacheURL, options: .atomic)
        } catch {
#if DEBUG
            print("Yomi could not persist translation cache: \(error)")
#endif
        }
    }

    private func translationCacheKey(
        for lines: [String],
        targetLanguage: String
    ) -> String {
        let input = ([targetLanguage] + lines).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func translationCacheURL(for cacheKey: String) -> URL? {
        translationCacheDirectoryURL?
            .appendingPathComponent(cacheKey)
            .appendingPathExtension("json")
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiration.timeIntervalSinceNow > 30 {
            return accessToken
        }

        var request = URLRequest(url: authenticationURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200 ..< 300).contains(httpResponse.statusCode),
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token.split(separator: ".").count == 3
        else {
            throw ClientError.invalidResponse
        }

        accessToken = token
        accessTokenExpiration = Date().addingTimeInterval(8 * 60)
        return token
    }

    private func requestTranslation(
        _ lines: [String],
        targetLanguage: String,
        accessToken: String
    ) async throws -> [String] {
        var components = URLComponents(
            url: translationURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "from", value: "ja"),
            URLQueryItem(name: "to", value: targetLanguage)
        ]
        guard let url = components?.url else {
            throw ClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            lines.map { TranslationRequest(text: $0) }
        )
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-ClientTraceId")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
#if DEBUG
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            print(
                "Yomi Bing Translate failed: HTTP \(httpResponse.statusCode), "
                    + "request \(httpResponse.value(forHTTPHeaderField: "X-RequestId") ?? "unknown"), "
                    + "body \(responseBody)"
            )
#endif
            throw ClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let responseItems = try JSONDecoder().decode(
            [TranslationResponseItem].self,
            from: data
        )
        let translatedLines = responseItems.compactMap {
            $0.translations?.first?.text
        }
        guard
            translatedLines.count == lines.count,
            translatedLines.allSatisfy({ !$0.isEmpty })
        else {
            throw ClientError.emptyTranslation
        }
        return translatedLines
    }

    private func requestWebsiteTranslation(
        _ lines: [String],
        targetLanguage: String
    ) async throws -> [String] {
        var translatedLines: [String] = []
        for line in lines {
            let chunks = line.chunked(maximumCharacterCount: 3_000)
            var translatedChunks: [String] = []
            for chunk in chunks {
                translatedChunks.append(
                    try await requestWebsiteTranslation(
                        chunk,
                        targetLanguage: targetLanguage,
                        mayRefreshConfiguration: true
                    )
                )
            }
            translatedLines.append(translatedChunks.joined())
        }
        return translatedLines
    }

    private func requestWebsiteTranslation(
        _ text: String,
        targetLanguage: String,
        mayRefreshConfiguration: Bool
    ) async throws -> String {
        let configuration = try await validWebsiteConfiguration()
        var components = URLComponents()
        components.scheme = "https"
        components.host = configuration.host
        components.path = "/ttranslatev3"
        components.queryItems = [
            URLQueryItem(name: "isVertical", value: "1"),
            URLQueryItem(name: "IG", value: configuration.ig),
            URLQueryItem(name: "IID", value: configuration.iid),
            URLQueryItem(name: "SFX", value: String(configuration.requestCount + 1)),
            URLQueryItem(name: "ref", value: "TThis"),
            URLQueryItem(name: "edgepdftranslator", value: "1")
        ]
        guard let url = components.url else {
            throw ClientError.invalidResponse
        }

        websiteConfiguration?.requestCount += 1

        var formComponents = URLComponents()
        formComponents.queryItems = [
            URLQueryItem(name: "fromLang", value: "ja"),
            URLQueryItem(name: "to", value: targetLanguage),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "token", value: configuration.token),
            URLQueryItem(name: "key", value: String(configuration.key)),
            URLQueryItem(
                name: "tryFetchingGenderDebiasedTranslations",
                value: "true"
            )
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = formComponents.percentEncodedQuery?.data(using: .utf8)
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "https://\(configuration.host)/translator",
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await websiteSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
#if DEBUG
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            print(
                "Yomi Bing website translation failed: HTTP \(httpResponse.statusCode), "
                    + "body \(responseBody)"
            )
#endif
            if mayRefreshConfiguration,
               httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                websiteConfiguration = nil
                return try await requestWebsiteTranslation(
                    text,
                    targetLanguage: targetLanguage,
                    mayRefreshConfiguration: false
                )
            }
            throw ClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let responseItems = try JSONDecoder().decode(
            [TranslationResponseItem].self,
            from: data
        )
        guard
            let translation = responseItems.first?.translations?.first?.text,
            !translation.isEmpty
        else {
            throw ClientError.emptyTranslation
        }
        return translation
    }

    private func validWebsiteConfiguration() async throws -> WebsiteConfiguration {
        if let websiteConfiguration,
           websiteConfiguration.expiration.timeIntervalSinceNow > 30 {
            return websiteConfiguration
        }

        var request = URLRequest(url: websiteURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await websiteSession.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200 ..< 300).contains(httpResponse.statusCode),
            let html = String(data: data, encoding: .utf8),
            let ig = html.firstCapture(for: #"IG:"([^"]+)""#),
            let iid = html.firstCapture(for: #"data-iid="([^"]+)""#),
            let abusePreventionParameters = html.firstCapture(
                for: #"params_AbusePreventionHelper\s*=\s*(\[[^\]]+\])"#
            ),
            let parametersData = abusePreventionParameters.data(using: .utf8),
            let parameters = try JSONSerialization.jsonObject(
                with: parametersData
            ) as? [Any],
            parameters.count >= 3,
            let key = parameters[0] as? NSNumber,
            let token = parameters[1] as? String,
            let expirationInterval = parameters[2] as? NSNumber
        else {
            throw ClientError.invalidResponse
        }

        let responseHost = response.url?.host
        let host = responseHost?.hasSuffix(".bing.com") == true
            ? responseHost!
            : "www.bing.com"
        let configuration = WebsiteConfiguration(
            host: host,
            ig: ig,
            iid: iid,
            key: key.int64Value,
            token: token,
            expiration: Date().addingTimeInterval(
                expirationInterval.doubleValue / 1_000
            ),
            requestCount: 0
        )
        websiteConfiguration = configuration
        return configuration
    }
}

private nonisolated struct TranslationCacheRecord: Codable, Sendable {
    let sourceLines: [String]
    let targetLanguage: String
    let translatedLines: [String]
}

private struct TranslationRequest: Encodable {
    let text: String

    enum CodingKeys: String, CodingKey {
        case text = "Text"
    }
}

private struct TranslationResponseItem: Decodable {
    let translations: [TranslationResponse]?
}

private struct TranslationResponse: Decodable {
    let text: String
}

private struct WebsiteConfiguration {
    let host: String
    let ig: String
    let iid: String
    let key: Int64
    let token: String
    let expiration: Date
    var requestCount: Int
}

private extension String {
    nonisolated func firstCapture(for pattern: String) -> String? {
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: self,
                range: NSRange(startIndex..., in: self)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: self)
        else {
            return nil
        }
        return String(self[range])
    }

    nonisolated func chunked(maximumCharacterCount: Int) -> [String] {
        guard count > maximumCharacterCount else { return [self] }

        var result: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(
                start,
                offsetBy: maximumCharacterCount,
                limitedBy: endIndex
            ) ?? endIndex
            result.append(String(self[start ..< end]))
            start = end
        }
        return result
    }
}
