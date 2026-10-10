import Foundation
import NeedleCore

// Usage: swift run -c release NeedleBench [--docs N] [--folder PATH] [--queries N]

var docCount = 20_000
var folder: String? = nil
var queryCount = 5_000

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--docs": if let v = args.first, let n = Int(v) { docCount = n; args.removeFirst() }
    case "--queries": if let v = args.first, let n = Int(v) { queryCount = n; args.removeFirst() }
    case "--folder": if let v = args.first { folder = v; args.removeFirst() }
    default: print("Unknown argument \(a)")
    }
}

@inline(__always) func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    if sorted.isEmpty { return 0 }
    let i = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[i]
}

func fmt(_ micros: Double) -> String {
    if micros >= 1000 { return String(format: "%.2f ms", micros / 1000) }
    return String(format: "%.1f µs", micros)
}

// 1. Corpus
let documents: [Document]
if let folder = folder {
    print("Loading \(folder) …")
    documents = FolderLoader.load(from: URL(fileURLWithPath: folder))
} else {
    print("Generating \(docCount) demo documents …")
    documents = DemoCorpus.generate(count: docCount)
}
if documents.isEmpty { print("No documents."); exit(1) }

// 2. Index
let index = SearchIndex(documents: documents)
let mb = Double(index.byteCount) / 1_048_576
print(String(format: "Indexed %d docs, %.1f MB in %.2f s (%.1f MB/s), %d suffixes",
             index.docCount, mb, index.buildSeconds, mb / max(index.buildSeconds, 0.0001), index.suffixCount))

// 3. Queries: random substrings of random words from the corpus
var rng = SystemRandomNumberGenerator()
var queries: [String] = []
var guardCount = 0
while queries.count < queryCount && guardCount < queryCount * 20 {
    guardCount += 1
    let d = documents[Int.random(in: 0..<documents.count, using: &rng)]
    let words = d.body.split(whereSeparator: { $0 == " " || $0 == "\n" })
    guard let w = words.randomElement(using: &rng), w.count >= 3 else { continue }
    let len = Int.random(in: 3...min(10, w.count), using: &rng)
    let start = Int.random(in: 0...(w.count - len), using: &rng)
    let s = w.index(w.startIndex, offsetBy: start)
    let e = w.index(s, offsetBy: len)
    queries.append(String(w[s..<e]))
}
print("Using \(queries.count) random substring queries (3–10 chars)\n")

// 4a. Cold: every query from scratch (no keystroke reuse).
var cold: [Double] = []
var approximate = 0
for q in queries {
    var session = SearchSession()
    let t = nowNanos()
    let r = index.search(q, limit: 20, session: &session)
    cold.append(Double(nowNanos() - t) / 1000)
    if r.isApproximate { approximate += 1 }
}
cold.sort()
print("Cold query (full ranked top-20 with snippets)")
print("  p50 \(fmt(percentile(cold, 0.50)))   p95 \(fmt(percentile(cold, 0.95)))   p99 \(fmt(percentile(cold, 0.99)))   max \(fmt(cold.last ?? 0))")
print("  approximate results: \(approximate) of \(queries.count)\n")

// 4b. Typing: one persistent session, character by character.
var perKey: [Double] = []
for q in queries.prefix(1_000) {
    var session = SearchSession()
    var typed = ""
    for ch in q {
        typed.append(ch)
        let t = nowNanos()
        _ = index.search(typed, limit: 20, session: &session)
        perKey.append(Double(nowNanos() - t) / 1000)
    }
}
perKey.sort()
print("Per keystroke while typing (interval reused from previous key)")
print("  p50 \(fmt(percentile(perKey, 0.50)))   p95 \(fmt(percentile(perKey, 0.95)))   p99 \(fmt(percentile(perKey, 0.99)))\n")

// 5. Baseline: linear scan of the whole corpus (the thing a suffix array replaces).
let baselineQueries = queries.prefix(200)
let tb = nowNanos()
var sink = 0
for q in baselineQueries { sink &+= index.bruteForceCount(q).occurrences }
let baselineMicros = Double(nowNanos() - tb) / 1000 / Double(max(1, baselineQueries.count))
let coldMean = cold.reduce(0, +) / Double(max(1, cold.count))
print("Linear scan baseline (count only, no ranking): mean \(fmt(baselineMicros))  [\(sink) total occurrences]")
print("Needle cold mean: \(fmt(coldMean))  →  \(String(format: "%.0f", baselineMicros / max(coldMean, 0.001)))x faster, and ranked")
