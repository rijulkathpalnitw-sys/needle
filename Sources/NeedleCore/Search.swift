import Foundation

// MARK: - Results

public struct SearchHit: Identifiable, Sendable {
    /// Document index in the order the documents were indexed.
    public let id: Int
    public let title: String
    public let snippet: String
    public let reference: String
    public let score: Float
    /// Total occurrences of all query terms in this document (capped per term).
    public let matches: Int
}

public struct SearchResponse: Sendable {
    public var hits: [SearchHit] = []
    /// Documents that contain every term.
    public var matchingDocs = 0
    /// Occurrences of the rarest term (exact for a single-term query unless approximate).
    public var occurrences = 0
    public var microseconds: Double = 0
    /// True when a very common term hit `scanCap` or verification budget ran out.
    public var isApproximate = false
    public var terms: [String] = []
    /// Candidate suffix count after each keystroke of the last term: [total, after 1 char, ...].
    public var narrowing: [Int] = []

    public static let empty = SearchResponse()
    public init() {}
}

// MARK: - Incremental state

/// One query term and the suffix-array interval after every prefix of it.
/// `ranges[k]` is the interval of suffixes starting with the first k bytes.
struct TermCursor {
    var bytes: [UInt8] = []
    var ranges: [Range<Int>] = []

    var range: Range<Int> { ranges[ranges.count - 1] }
    var trail: [Int] { ranges.map { $0.count } }

    mutating func update(to newBytes: [UInt8], in index: SearchIndex) {
        if ranges.isEmpty { ranges = [0..<index.suffixCount] }
        // Longest shared prefix with what we already computed: reuse it, redo only the tail.
        var l = 0
        let m = min(bytes.count, newBytes.count)
        while l < m && bytes[l] == newBytes[l] { l += 1 }
        if ranges.count > l + 1 { ranges.removeSubrange((l + 1)...) }
        var k = l
        while k < newBytes.count {
            let prev = ranges[k]
            if k >= index.cap || prev.isEmpty {
                ranges.append(prev)           // beyond cap: verified later, no more narrowing
            } else {
                ranges.append(index.narrow(prev, depth: k, byte: newBytes[k]))
            }
            k += 1
        }
        bytes = newBytes
    }
}

struct Scratch {
    var tf: [UInt16]
    var firstOff: [UInt32]
    var flags: [UInt8]
    var touched: [Int32] = []

    init(docCount: Int) {
        tf = [UInt16](repeating: 0, count: docCount)
        firstOff = [UInt32](repeating: 0, count: docCount)
        flags = [UInt8](repeating: 0, count: docCount)
    }
}

/// Holds everything that makes the next keystroke cheaper: the narrowing state per term
/// and reusable per-document counters. Use one session per index; reuse it across queries.
public struct SearchSession {
    var cursors: [TermCursor] = []
    var scratch: Scratch? = nil
    public init() {}
}

// MARK: - Top-k

struct Cand {
    var doc: Int32
    var score: Float
    var off: UInt32
    var matches: UInt32
}

/// Bounded heap that keeps the k best candidates (best = higher score, then lower doc id).
struct TopK {
    let k: Int
    var items: [Cand] = []

    init(k: Int) {
        self.k = max(0, k)
        items.reserveCapacity(min(self.k, 4096))
    }

    @inline(__always)
    static func worse(_ a: Cand, _ b: Cand) -> Bool {
        return a.score < b.score || (a.score == b.score && a.doc > b.doc)
    }

    mutating func offer(_ c: Cand) {
        if k == 0 { return }
        if items.count < k {
            items.append(c)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) >> 1
                if TopK.worse(items[i], items[parent]) {
                    items.swapAt(i, parent)
                    i = parent
                } else { break }
            }
        } else if TopK.worse(items[0], c) {
            items[0] = c
            var i = 0
            let n = items.count
            while true {
                let l = 2 * i + 1, r = l + 1
                var w = i
                if l < n && TopK.worse(items[l], items[w]) { w = l }
                if r < n && TopK.worse(items[r], items[w]) { w = r }
                if w == i { break }
                items.swapAt(i, w)
                i = w
            }
        }
    }

    func sortedBestFirst() -> [Cand] {
        return items.sorted { TopK.worse($1, $0) }
    }
}

// MARK: - Search

extension SearchIndex {

    /// Splits a query into terms. Whitespace separates terms; "double quotes" keep spaces
    /// inside a single term, so `"user pro"` is a phrase substring.
    static func parseTerms(_ query: String) -> [[UInt8]] {
        var terms: [[UInt8]] = []
        var cur: [UInt8] = []
        var inQuote = false

        func flush() {
            while let f = cur.first, f == 32 { cur.removeFirst() }
            while let l = cur.last, l == 32 { cur.removeLast() }
            if cur.count > SearchIndex.maxTermBytes { cur.removeSubrange(SearchIndex.maxTermBytes...) }
            if !cur.isEmpty && !terms.contains(cur) && terms.count < SearchIndex.maxTerms {
                terms.append(cur)
            }
            cur.removeAll(keepingCapacity: true)
        }

        for b in query.utf8 {
            if b == 34 {            // "
                flush()
                inQuote.toggle()
                continue
            }
            let f = SearchIndex.fold(b)
            if f == 32 && !inQuote { flush() } else { cur.append(f) }
        }
        flush()
        return terms
    }

    /// flags: 1 = starts in the title, 2 = starts at a word boundary (incl. camelCase), 4 = whole word.
    @inline(__always)
    func matchFlags(pos: Int, len: Int, doc: Int) -> UInt8 {
        let off = pos - Int(docStarts[doc])
        var fl: UInt8 = 0
        if off < Int(titleLens[doc]) { fl |= 1 }
        var boundary = false
        if off == 0 {
            boundary = true
        } else {
            let prev = raw[pos - 1]
            let cur = raw[pos]
            if !SearchIndex.isWordByte(prev) {
                boundary = true
            } else if prev >= 97 && prev <= 122 && cur >= 65 && cur <= 90 {
                boundary = true        // fooBar -> "Bar" starts a word
            }
        }
        if boundary {
            fl |= 2
            if !SearchIndex.isWordByte(raw[pos + len]) { fl |= 4 }
        }
        return fl
    }

    @inline(__always)
    static func termScore(tf: Int, flags: UInt8) -> Float {
        var s = log2(1 + Float(tf))
        if flags & 1 != 0 { s += 4 }
        if flags & 2 != 0 { s += 1.5 }
        if flags & 4 != 0 { s += 1.5 }
        return s
    }

    @inline(__always)
    func normalized(_ s: Float, doc: Int) -> Float {
        let len = Float(Int(docEnds[doc]) - Int(docStarts[doc]))
        return s / (1 + 0.12 * log2(1 + len / 400))
    }

    /// Runs a query. Cost is dominated by two binary searches per new character plus
    /// a pass over the (usually tiny) matching interval of the rarest term.
    public func search(_ query: String, limit: Int = 25, session: inout SearchSession) -> SearchResponse {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var response = SearchResponse()
        let terms = SearchIndex.parseTerms(query)
        response.terms = terms.map { String(decoding: $0, as: UTF8.self) }

        func finish(_ r: SearchResponse) -> SearchResponse {
            var out = r
            out.microseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            return out
        }

        if terms.isEmpty || docCount == 0 {
            session.cursors.removeAll()
            return finish(response)
        }

        // 1. Narrow every term's interval, reusing last keystroke's work.
        while session.cursors.count < terms.count { session.cursors.append(TermCursor()) }
        if session.cursors.count > terms.count {
            session.cursors.removeLast(session.cursors.count - terms.count)
        }
        var ranges: [Range<Int>] = []
        for i in 0..<terms.count {
            session.cursors[i].update(to: terms[i], in: self)
            ranges.append(session.cursors[i].range)
        }
        response.narrowing = session.cursors[terms.count - 1].trail
        if ranges.contains(where: { $0.isEmpty }) { return finish(response) }

        // 2. The rarest term drives candidate generation.
        var driver = 0
        for i in 1..<terms.count where ranges[i].count < ranges[driver].count { driver = i }
        let dTerm = terms[driver]
        let dRange = ranges[driver]
        let scanEnd = min(dRange.upperBound, dRange.lowerBound + scanCap)
        if scanEnd < dRange.upperBound { response.isApproximate = true }

        var s = session.scratch ?? Scratch(docCount: docCount)
        session.scratch = nil
        defer {
            for d in s.touched { s.tf[Int(d)] = 0 }
            s.touched.removeAll(keepingCapacity: true)
            session.scratch = s
        }

        // 3. Walk the interval: every entry is one occurrence. Aggregate per document.
        var occurrences = 0
        var i = dRange.lowerBound
        while i < scanEnd {
            let pos = Int(suffixes[i])
            i += 1
            if dTerm.count > cap && !tailMatches(pos, dTerm) { continue }
            occurrences += 1
            let d = docIndex(forOffset: pos)
            let off = pos - Int(docStarts[d])
            let fl = matchFlags(pos: pos, len: dTerm.count, doc: d)
            if s.tf[d] == 0 {
                s.touched.append(Int32(d))
                s.firstOff[d] = UInt32(off)
                s.flags[d] = fl
            } else {
                s.flags[d] |= fl
                if UInt32(off) < s.firstOff[d] { s.firstOff[d] = UInt32(off) }
            }
            if s.tf[d] < UInt16.max { s.tf[d] += 1 }
        }
        response.occurrences = occurrences

        var top = TopK(k: limit)

        if terms.count == 1 {
            for d32 in s.touched {
                let d = Int(d32)
                let rawScore = SearchIndex.termScore(tf: Int(s.tf[d]), flags: s.flags[d])
                top.offer(Cand(doc: d32, score: normalized(rawScore, doc: d), off: s.firstOff[d], matches: UInt32(s.tf[d])))
            }
            response.matchingDocs = s.touched.count
        } else {
            // 4. AND semantics: verify the other terms inside candidate documents,
            //    best candidates first, within a work budget.
            let poolSize = min(s.touched.count, 20_000)
            var pool = TopK(k: poolSize)
            for d32 in s.touched {
                let d = Int(d32)
                let rawScore = SearchIndex.termScore(tf: Int(s.tf[d]), flags: s.flags[d])
                pool.offer(Cand(doc: d32, score: normalized(rawScore, doc: d), off: s.firstOff[d], matches: UInt32(s.tf[d])))
            }
            let ordered = pool.sortedBestFirst()
            let target = max(limit * 10, 500)
            let budget = 256 << 20
            var scanned = 0
            var confirmed = 0
            var processed = 0

            for c in ordered {
                if confirmed >= target || scanned > budget { break }
                processed += 1
                let d = Int(c.doc)
                let ds = Int(docStarts[d]), de = Int(docEnds[d])
                scanned += (de - ds) * (terms.count - 1)

                var sum = SearchIndex.termScore(tf: Int(s.tf[d]), flags: s.flags[d])
                var matches = Int(s.tf[d])
                var firstOff = Int(s.firstOff[d])
                var ok = true
                for ti in 0..<terms.count where ti != driver {
                    let term = terms[ti]
                    var p = find(term, from: ds, to: de)
                    if p < 0 { ok = false; break }
                    let fl = matchFlags(pos: p, len: term.count, doc: d)
                    firstOff = min(firstOff, p - ds)
                    var cnt = 0
                    while p >= 0 && cnt < 64 {
                        cnt += 1
                        p = find(term, from: p + 1, to: de)
                    }
                    sum += SearchIndex.termScore(tf: cnt, flags: fl)
                    matches += cnt
                }
                if ok {
                    confirmed += 1
                    top.offer(Cand(doc: c.doc, score: normalized(sum, doc: d), off: UInt32(firstOff), matches: UInt32(matches)))
                }
            }
            response.matchingDocs = confirmed
            if processed < s.touched.count { response.isApproximate = true }
        }

        // 5. Snippets for the winners only.
        let longest = terms.map { $0.count }.max() ?? 1
        response.hits = top.sortedBestFirst().map { c in
            let d = Int(c.doc)
            return SearchHit(
                id: d,
                title: titles[d],
                snippet: makeSnippet(doc: d, matchOffset: Int(c.off), matchLen: longest),
                reference: references[d],
                score: c.score,
                matches: Int(c.matches)
            )
        }
        return finish(response)
    }

    func makeSnippet(doc d: Int, matchOffset off: Int, matchLen: Int, radius: Int = 80) -> String {
        let ds = Int(docStarts[d]), de = Int(docEnds[d])
        let bodyStart = min(de, ds + Int(titleLens[d]) + 1)
        var lo: Int
        var hi: Int
        if off < Int(titleLens[d]) + 1 {
            lo = bodyStart                                   // match was in the title: show the opening
            hi = min(de, bodyStart + 2 * radius)
        } else {
            let m = ds + off
            lo = max(bodyStart, m - radius)
            hi = min(de, m + matchLen + radius)
        }
        // Stay on UTF-8 character boundaries.
        while lo < hi && (raw[lo] & 0xC0) == 0x80 { lo += 1 }
        while hi < de && (raw[hi] & 0xC0) == 0x80 { hi += 1 }
        if lo >= hi { return "" }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hi - lo)
        for k in lo..<hi { bytes.append(raw[k] < 32 ? 32 : raw[k]) }
        var s = String(decoding: bytes, as: UTF8.self)
        if lo > bodyStart { s = "…" + s }
        if hi < de { s += "…" }
        return s
    }

    // MARK: Baseline (for tests and benchmarks)

    /// Naive linear scan over the whole corpus. Returns overlapping occurrence count and
    /// number of distinct documents. This is what the suffix array replaces.
    public func bruteForceCount(_ query: String) -> (occurrences: Int, documents: Int) {
        let terms = SearchIndex.parseTerms(query)
        guard let term = terms.first, byteCount > 0 else { return (0, 0) }
        var occ = 0
        var docs = 0
        var lastDoc = -1
        var p = find(term, from: 0, to: byteCount)
        while p >= 0 {
            occ += 1
            let d = docIndex(forOffset: p)
            if d != lastDoc { docs += 1; lastDoc = d }
            p = find(term, from: p + 1, to: byteCount)
        }
        return (occ, docs)
    }
}
