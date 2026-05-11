import Foundation

struct CompanyKnowledgeSource: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case url
        case file
        case markdown
    }

    var id: String
    var kind: Kind
    var location: String
    var lastFetchedAt: Date
    var refreshCadenceHours: Int

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(lastFetchedAt) >= Double(refreshCadenceHours) * 3_600
    }
}

struct CompanyKnowledgeChunk: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var sourceID: String
    var text: String
    var provenance: String
    var lastFetchedAt: Date
    var embedding: [String: Double]
}

struct CompanyKnowledgeRetrieval: Codable, Hashable {
    var chunk: CompanyKnowledgeChunk
    var score: Double
}

struct CompanyKnowledgeBase: Codable, Hashable {
    var companyID: String
    var sources: [CompanyKnowledgeSource]
    var chunks: [CompanyKnowledgeChunk]
    var embeddingProviderAllowlist: Set<String>
}

enum CompanyKnowledgeBaseService {
    static func ingestMarkdown(
        companyID: String,
        sourceID: String,
        markdown: String,
        provenance: String,
        fetchedAt: Date,
        refreshCadenceHours: Int = 24,
        embeddingProvider: String,
        accessControl: CompanyAccessControl
    ) -> CompanyKnowledgeBase? {
        guard accessControl.embeddingProviderAllowlist.contains(embeddingProvider) else { return nil }
        let source = CompanyKnowledgeSource(id: sourceID, kind: .markdown, location: provenance, lastFetchedAt: fetchedAt, refreshCadenceHours: refreshCadenceHours)
        let chunks = chunk(markdown, maxWords: 80).enumerated().map { offset, text in
            CompanyKnowledgeChunk(
                id: "\(companyID)-\(sourceID)-\(offset)",
                companyID: companyID,
                sourceID: sourceID,
                text: text,
                provenance: provenance,
                lastFetchedAt: fetchedAt,
                embedding: embed(text)
            )
        }
        return CompanyKnowledgeBase(
            companyID: companyID,
            sources: [source],
            chunks: chunks,
            embeddingProviderAllowlist: accessControl.embeddingProviderAllowlist
        )
    }

    static func chunk(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return stride(from: 0, to: words.count, by: maxWords).map { start in
            words[start..<min(start + maxWords, words.count)].joined(separator: " ")
        }
    }

    static func retrieve(query: String, kb: CompanyKnowledgeBase, k: Int) -> [CompanyKnowledgeRetrieval] {
        let queryEmbedding = embed(query)
        return kb.chunks
            .map { CompanyKnowledgeRetrieval(chunk: $0, score: cosine(queryEmbedding, $0.embedding)) }
            .sorted {
                if $0.score == $1.score { return $0.chunk.id < $1.chunk.id }
                return $0.score > $1.score
            }
            .prefix(k)
            .map { $0 }
    }

    static func draftGroundedReply(question: String, retrievals: [CompanyKnowledgeRetrieval]) -> String? {
        guard let best = retrievals.first else { return nil }
        let quote = best.chunk.text.split(separator: ".").first.map(String.init) ?? best.chunk.text
        let words = quote.split(whereSeparator: \.isWhitespace).prefix(15).joined(separator: " ")
        return "\(words)."
    }

    static func hallucinationFlags(draft: String, kb: CompanyKnowledgeBase) -> [String] {
        CompanyContentQualityScorer.score(
            input: CompanyContentQualityInput(
                draft: draft,
                channel: .contentPosts,
                voiceProfile: "sourced",
                publishedCorpus: [],
                knowledgeBaseCorpus: kb.chunks.map(\.text)
            )
        ).score.hallucinationFlags
    }

    private static func embed(_ text: String) -> [String: Double] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .reduce(into: [:]) { counts, token in counts[token, default: 0] += 1 }
    }

    private static func cosine(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        let keys = Set(lhs.keys).union(rhs.keys)
        let dot = keys.map { (lhs[$0] ?? 0) * (rhs[$0] ?? 0) }.reduce(0, +)
        let lhsNorm = sqrt(lhs.values.map { $0 * $0 }.reduce(0, +))
        let rhsNorm = sqrt(rhs.values.map { $0 * $0 }.reduce(0, +))
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (lhsNorm * rhsNorm)
    }
}
