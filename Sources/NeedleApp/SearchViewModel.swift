#if canImport(SwiftUI)
import SwiftUI
import NeedleCore

enum IndexState {
    case empty
    case building(String)
    case ready(docs: Int, bytes: Int, seconds: Double)
    case failed(String)
}

/// Owns the index and the incremental session. All searching happens on this actor so the
/// session state (the per-keystroke intervals) is never touched from two places at once.
actor SearchEngine {
    private var index: SearchIndex?
    private var session = SearchSession()

    func install(_ newIndex: SearchIndex) {
        index = newIndex
        session = SearchSession()
    }

    func search(_ query: String, limit: Int) -> SearchResponse? {
        guard let index = index else { return nil }
        return index.search(query, limit: limit, session: &session)
    }

    func body(of doc: Int) -> String? {
        guard let index = index else { return nil }
        return index.body(of: doc)
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var response = SearchResponse.empty
    @Published private(set) var state: IndexState = .empty
    @Published var selection: Int? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    @Published private(set) var selectedHit: SearchHit?
    @Published private(set) var detail = AttributedString()

    private let engine = SearchEngine()
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var generation = 0
    private var detailBody = ""

    // MARK: Indexing

    func buildDemo(count: Int) {
        reset(message: "Generating \(count.formatted()) documents…")
        let engine = self.engine
        Task {
            let index = await Task.detached(priority: .userInitiated) { () -> SearchIndex in
                let docs = DemoCorpus.generate(count: count)
                return SearchIndex(documents: docs)
            }.value
            await engine.install(index)
            self.state = .ready(docs: index.docCount, bytes: index.byteCount, seconds: index.buildSeconds)
            self.scheduleSearch()
        }
    }

    func buildFolder(url: URL) {
        reset(message: "Reading \(url.lastPathComponent)…")
        let engine = self.engine
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            let index = await Task.detached(priority: .userInitiated) { () -> SearchIndex? in
                let docs = FolderLoader.load(from: url)
                if docs.isEmpty { return nil }
                return SearchIndex(documents: docs)
            }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let index = index else {
                self.state = .failed("No readable text files found in that folder.")
                return
            }
            await engine.install(index)
            self.state = .ready(docs: index.docCount, bytes: index.byteCount, seconds: index.buildSeconds)
            self.scheduleSearch()
        }
    }

    private func reset(message: String) {
        state = .building(message)
        response = .empty
        selection = nil
        selectedHit = nil
        detail = AttributedString()
        detailBody = ""
    }

    // MARK: Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        generation += 1
        let g = generation
        let q = query
        let engine = self.engine
        searchTask = Task {
            guard let r = await engine.search(q, limit: 60) else { return }
            if Task.isCancelled || g != self.generation { return }
            self.response = r
            self.rehighlight()
        }
    }

    // MARK: Detail pane

    private func loadSelection() {
        guard let id = selection else { return }
        if let hit = response.hits.first(where: { $0.id == id }) { selectedHit = hit }
        let engine = self.engine
        detailTask?.cancel()
        detailTask = Task {
            let body = await engine.body(of: id) ?? ""
            if Task.isCancelled { return }
            self.detailBody = String(body.prefix(200_000))
            self.rehighlight()
        }
    }

    private func rehighlight() {
        guard !detailBody.isEmpty else { return }
        let text = detailBody
        let terms = response.terms
        highlightTask?.cancel()
        highlightTask = Task {
            let attributed = await Task.detached(priority: .userInitiated) {
                Highlight.attributed(text, terms: terms, limitPerTerm: 400)
            }.value
            if Task.isCancelled { return }
            self.detail = attributed
        }
    }
}

enum Highlight {
    static func attributed(_ text: String, terms: [String], limitPerTerm: Int = 100) -> AttributedString {
        var out = AttributedString(text)
        for term in terms where !term.isEmpty {
            var from = out.startIndex
            var count = 0
            while from < out.endIndex, count < limitPerTerm,
                  let r = out[from...].range(of: term, options: .caseInsensitive) {
                out[r].backgroundColor = Color.yellow.opacity(0.35)
                out[r].foregroundColor = Color.primary
                from = r.upperBound
                count += 1
            }
        }
        return out
    }
}
#endif
