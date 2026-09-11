import Foundation

/// Normalizes the base URL or full chat endpoint entered for a compatible provider.
/// The settings UI accepts both `https://host/v1` and a complete chat endpoint.
enum SummaryModelEndpoint {
    private static let chatSuffixes = [
        "/chat/completions",
        "/text/chatcompletion_v2"
    ]

    static func chatCompletionsURL(from rawEndpoint: String) throws -> URL {
        let value = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw SummaryEngineError.invalidEndpoint
        }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }

        let lowercasedPath = path.lowercased()
        let isKnownChatEndpoint = chatSuffixes.contains {
            lowercasedPath.hasSuffix($0)
        }
        if !isKnownChatEndpoint {
            path = path.isEmpty
                ? "/v1/chat/completions"
                : "\(path)/chat/completions"
        }

        components.path = path
        guard let endpoint = components.url else {
            throw SummaryEngineError.invalidEndpoint
        }
        return endpoint
    }

    static func modelsURL(from chatEndpoint: URL) -> URL? {
        guard var components = URLComponents(
            url: chatEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        let lowercasedPath = components.path.lowercased()
        guard let suffix = chatSuffixes.first(where: {
            lowercasedPath.hasSuffix($0)
        }) else {
            return nil
        }

        let basePath = String(components.path.dropLast(suffix.count))
        components.path = (basePath.isEmpty ? "" : basePath) + "/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum SummaryModelDiscoveryError: Error {
    case invalidPayload
}

/// Parses the model-list variants commonly returned by OpenAI-compatible gateways.
enum SummaryModelDiscovery {
    private static let candidateKeys = ["data", "models", "items", "result", "response"]
    private static let modelKeys = ["id", "name", "model", "model_id", "modelId", "slug"]

    static func parse(_ data: Data) throws -> [String] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw SummaryModelDiscoveryError.invalidPayload
        }

        guard let entries = modelEntries(in: object) else {
            throw SummaryModelDiscoveryError.invalidPayload
        }

        var values: [String] = []
        for entry in entries {
            let value: String?
            if let string = entry as? String {
                value = string
            } else if let object = entry as? [String: Any] {
                value = modelKeys
                    .compactMap { object[$0] as? String }
                    .first
            } else {
                value = nil
            }

            guard let value else { continue }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            values.append(clean)
        }

        if !entries.isEmpty && values.isEmpty {
            throw SummaryModelDiscoveryError.invalidPayload
        }

        return sortedUnique(values)
    }

    static func sortedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
    }

    static func selectionAfterDiscovery(
        current: String,
        available: [String]
    ) -> String? {
        let cleanCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCurrent.isEmpty else { return nil }
        return available.first { $0 == cleanCurrent }
    }

    static func selectionCandidate(current: String, pending: String?) -> String {
        let cleanCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanCurrent.isEmpty {
            return cleanCurrent
        }
        return pending?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func modelEntries(in value: Any) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }

        guard let object = value as? [String: Any] else {
            return nil
        }

        for key in candidateKeys {
            guard let nested = object[key] else { continue }
            if let entries = modelEntries(in: nested) {
                return entries
            }
        }
        return nil
    }
}
