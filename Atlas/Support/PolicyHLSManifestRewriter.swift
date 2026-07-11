import Foundation
import PipedKit

nonisolated private let policyMediaURIAttributeExpression = try? NSRegularExpression(
    pattern: #"URI="([^"]+)""#)

extension PolicyMediaAssetFactory {
    enum ManifestError: Error, LocalizedError, Sendable, Equatable {
        case inputTooLarge(maximumBytes: Int)
        case outputTooLarge(maximumBytes: Int)
        case tooManyLines(maximum: Int)
        case lineTooLong(maximumBytes: Int)
        case tooMuchWork(maximumUnits: Int)

        var errorDescription: String? {
            switch self {
            case .inputTooLarge(let maximumBytes):
                "The HLS manifest exceeded the \(maximumBytes) byte input limit."
            case .outputTooLarge(let maximumBytes):
                "The rewritten HLS manifest exceeded the \(maximumBytes) byte output limit."
            case .tooManyLines(let maximum):
                "The HLS manifest exceeded the \(maximum) line limit."
            case .lineTooLong(let maximumBytes):
                "An HLS manifest line exceeded the \(maximumBytes) byte limit."
            case .tooMuchWork(let maximumUnits):
                "The HLS manifest exceeded the \(maximumUnits) rewrite work limit."
            }
        }
    }

    nonisolated static func rewriteHLSManifest(_ data: Data, baseURL: URL) throws -> Data {
        guard data.count <= maximumManifestInputBytes else {
            throw ManifestError.inputTooLarge(maximumBytes: maximumManifestInputBytes)
        }
        guard var manifest = String(data: data, encoding: .utf8),
            manifest.range(of: "#EXTM3U", options: .caseInsensitive) != nil
        else {
            return data
        }
        var lines = manifest.components(separatedBy: "\n")
        guard lines.count <= maximumManifestLines else {
            throw ManifestError.tooManyLines(maximum: maximumManifestLines)
        }
        var workUnits = 0
        for index in lines.indices {
            let line = lines[index]
            guard line.utf8.count <= maximumManifestLineBytes else {
                throw ManifestError.lineTooLong(maximumBytes: maximumManifestLineBytes)
            }
            try consumeWork(1, current: &workUnits)
            if line.hasPrefix("#") {
                lines[index] = try rewriteURIAttributes(
                    in: line,
                    baseURL: baseURL,
                    workUnits: &workUnits)
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try consumeWork(1, current: &workUnits)
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                let trailing = line.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
                lines[index] = leading + (try encodedReference(trimmed, baseURL: baseURL)) + trailing
            }
        }

        var outputBytes = 0
        for (index, line) in lines.enumerated() {
            let separatorBytes = index == 0 ? 0 : 1
            let (withLine, lineOverflow) = outputBytes.addingReportingOverflow(line.utf8.count)
            let (withSeparator, separatorOverflow) = withLine.addingReportingOverflow(separatorBytes)
            guard !lineOverflow, !separatorOverflow,
                withSeparator <= maximumManifestOutputBytes
            else {
                throw ManifestError.outputTooLarge(maximumBytes: maximumManifestOutputBytes)
            }
            outputBytes = withSeparator
        }
        manifest = lines.joined(separator: "\n")
        guard let rewritten = manifest.data(using: .utf8) else {
            throw NetworkPolicyError.invalidURL
        }
        return rewritten
    }

    nonisolated private static func rewriteURIAttributes(
        in line: String,
        baseURL: URL,
        workUnits: inout Int
    ) throws -> String {
        guard let policyMediaURIAttributeExpression else {
            throw NetworkPolicyError.invalidURL
        }
        var result = line
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = policyMediaURIAttributeExpression.matches(in: result, range: range)
        try consumeWork(matches.count, current: &workUnits)
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                let valueRange = Range(match.range(at: 1), in: result)
            else { continue }
            let encoded = try encodedReference(String(result[valueRange]), baseURL: baseURL)
            result.replaceSubrange(valueRange, with: encoded)
        }
        return result
    }

    nonisolated private static func consumeWork(_ amount: Int, current: inout Int) throws {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, next <= maximumManifestWorkUnits else {
            throw ManifestError.tooMuchWork(maximumUnits: maximumManifestWorkUnits)
        }
        current = next
    }

    nonisolated private static func encodedReference(_ raw: String, baseURL: URL) throws -> String {
        guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            throw NetworkPolicyError.invalidURL
        }
        return try policyURL(for: resolved).absoluteString
    }
}
