import Foundation

/// Chapter serialization and resource loading never run on the UI actor.
actor AnalysisDocumentBuilder {
    static let shared = AnalysisDocumentBuilder()
    private var template: String?
    private var script: String?

    func document(paragraphs: [String], initialIndex: Int, labels: [String: String]) -> String {
        if template == nil, let url = Bundle.main.url(forResource: "AnalysisReader", withExtension: "html") {
            template = try? String(contentsOf: url, encoding: .utf8)
        }
        if script == nil, let url = Bundle.main.url(forResource: "AnalysisReader", withExtension: "js") {
            script = try? String(contentsOf: url, encoding: .utf8)
        }
        let data = (try? JSONSerialization.data(withJSONObject: [
            "paragraphs": paragraphs, "initialIndex": initialIndex, "labels": labels
        ])) ?? Data()
        // JSON is embedded as script data: escape '<' to prevent a book's </script> from closing it.
        let json = (String(data: data, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return (template ?? "") + "<script>window.analysisConfiguration = \(json);</script><script>\(script ?? "")</script></body></html>"
    }
}
