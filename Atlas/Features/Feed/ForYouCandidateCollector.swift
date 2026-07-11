import PipedKit

enum ForYouCandidateResult {
    case search([StreamItem])
    case saved([StreamItem])
    case subscription([StreamItem])
    case related([StreamItem], [String: Int])
    case exploration([StreamItem], [String: Int])
}

@MainActor
final class ForYouCandidateCollector {
    let totalSources: Int
    var completedSources = 0
    var didPresentPersonalized = false
    var didStartDiscovery = false
    var renderRevision = 0

    private var searchCandidates: [StreamItem] = []
    private var savedCandidates: [StreamItem] = []
    private var subscriptionCandidates: [StreamItem] = []
    private var relatedCandidates: [StreamItem] = []
    private var relatedFrequency: [String: Int] = [:]
    private var explorationCandidates: [StreamItem] = []
    private var explorationFrequency: [String: Int] = [:]

    var isComplete: Bool {
        completedSources >= totalSources
    }

    var pool: CandidatePool {
        RecommendationEngine.mergeCandidateSources([
            CandidateSourceBucket(
                source: .subscription,
                items: subscriptionCandidates,
                limit: 18),
            CandidateSourceBucket(
                source: .related,
                items: relatedCandidates,
                frequency: relatedFrequency,
                limit: 24),
            CandidateSourceBucket(source: .saved, items: savedCandidates, limit: 12),
            CandidateSourceBucket(source: .search, items: searchCandidates, limit: 12),
            CandidateSourceBucket(
                source: .exploration,
                items: explorationCandidates,
                frequency: explorationFrequency,
                limit: 6),
        ])
    }

    init(totalSources: Int) {
        self.totalSources = totalSources
    }

    func apply(_ result: ForYouCandidateResult) {
        completedSources += 1
        switch result {
        case .search(let items):
            searchCandidates = items
        case .saved(let items):
            savedCandidates = items
        case .subscription(let items):
            subscriptionCandidates = items
        case .related(let items, let frequency):
            relatedCandidates = items
            relatedFrequency = frequency
        case .exploration(let items, let frequency):
            explorationCandidates = items
            explorationFrequency = frequency
        }
    }
}
