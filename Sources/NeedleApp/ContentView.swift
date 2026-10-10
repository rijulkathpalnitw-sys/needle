#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import NeedleCore

struct ContentView: View {
    @EnvironmentObject private var vm: SearchViewModel
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 680)
        } detail: {
            DocumentDetail()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Demo corpus · 1,000 docs") { vm.buildDemo(count: 1_000) }
                    Button("Demo corpus · 5,000 docs") { vm.buildDemo(count: 5_000) }
                    Button("Demo corpus · 20,000 docs") { vm.buildDemo(count: 20_000) }
                    Divider()
                    Button("Index a folder…") { showImporter = true }
                } label: {
                    Label("Index", systemImage: "externaldrive")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { vm.buildFolder(url: url) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search any substring…", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .padding([.horizontal, .top], 12)

            NarrowingView(counts: vm.response.narrowing)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            if vm.response.hits.isEmpty {
                EmptyResults()
            } else {
                List(vm.response.hits, selection: $vm.selection) { hit in
                    ResultRow(hit: hit, terms: vm.response.terms)
                }
                .listStyle(.plain)
            }

            StatusBar()
        }
        .onAppear { searchFocused = true }
    }
}

// MARK: - Pieces

struct EmptyResults: View {
    @EnvironmentObject private var vm: SearchViewModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            if vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type any fragment")
                    .font(.headline)
                Text("Needle matches inside words: try  urlsess  ·  0xdead  ·  @example.com  ·  \"user pro\"")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Text("No matches").font(.headline)
                Text("Every term must appear in the same document.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ResultRow: View {
    let hit: SearchHit
    let terms: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hit.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(hit.matches)×")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(Highlight.attributed(hit.snippet, terms: terms))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
    }
}

/// One bar per keystroke: how many suffixes are still candidates after that character.
/// This is the "narrowing" the engine does instead of re-searching from scratch.
struct NarrowingView: View {
    let counts: [Int]

    var body: some View {
        if counts.count > 1, let total = counts.first {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { item in
                        Capsule()
                            .fill(Color.accentColor.opacity(item.offset == counts.count - 1 ? 1 : 0.45))
                            .frame(width: 7, height: barHeight(item.element, total: total))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 30, alignment: .bottom)
                Text("candidates per keystroke · \(Self.format(total)) → \(Self.format(counts.last ?? 0))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Color.clear.frame(height: 4)
        }
    }

    private func barHeight(_ c: Int, total: Int) -> CGFloat {
        let denom = log10(Double(max(total, 2)) + 1)
        let v = log10(Double(c) + 1) / denom
        return max(3, 30 * CGFloat(v))
    }

    static func format(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var vm: SearchViewModel

    var body: some View {
        HStack(spacing: 8) {
            switch vm.state {
            case .empty:
                Text("No index")
            case .building(let message):
                ProgressView().controlSize(.small)
                Text(message)
            case .ready(let docs, let bytes, let seconds):
                Text("\(NarrowingView.format(docs)) docs · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · indexed in \(String(format: "%.2f", seconds)) s")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
            Spacer()
            if !vm.query.isEmpty, !vm.response.terms.isEmpty {
                Text(summary(vm.response)).monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func summary(_ r: SearchResponse) -> String {
        let time = r.microseconds >= 1000
            ? String(format: "%.2f ms", r.microseconds / 1000)
            : String(format: "%.0f µs", r.microseconds)
        let approx = r.isApproximate ? "~" : ""
        return "\(approx)\(NarrowingView.format(r.matchingDocs)) docs · \(time)"
    }
}

struct DocumentDetail: View {
    @EnvironmentObject private var vm: SearchViewModel

    var body: some View {
        if let hit = vm.selectedHit {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(hit.title).font(.title2.bold())
                    if !hit.reference.isEmpty {
                        Text(hit.reference).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(vm.detail)
                        .textSelection(.enabled)
                        .font(.body)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a result to read it").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
