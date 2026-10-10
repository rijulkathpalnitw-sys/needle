import Foundation

// MARK: - Public model

public struct Document: Sendable {
    public var title: String
    public var body: String
    /// Anything the UI wants to show or open later (a file path, a URL, an id).
    public var reference: String

    public init(title: String, body: String, reference: String = "") {
        self.title = title
        self.body = body
        self.reference = reference
    }
}

struct SuffixKey {
    var key: UInt64   // first 8 bytes of the suffix, big-endian, NUL-padded after the end
    var pos: UInt32
}

// MARK: - SearchIndex

/// Needle's index: one suffix array over the whole (case-folded) corpus.
///
/// There is no tokenizer and no inverted index. Every byte offset in the corpus is a
/// searchable entry point, so any substring of any length matches: the middle of a word,
/// an identifier fragment, a hex string, CJK text, punctuation, a phrase containing spaces.
///
/// A query is answered by binary-searching the suffix array. The matching suffixes always
/// form one contiguous interval, and the interval for "swif" lies inside the interval for
/// "swi". `TermCursor` keeps that interval per keystroke, so typing one more character
/// costs two small binary searches inside the previous interval, and backspace costs nothing.
public final class SearchIndex: @unchecked Sendable {
    public static let defaultCap = 48
    static let maxTerms = 6
    static let maxTermBytes = 256

    public let docCount: Int
    /// Size of the folded corpus in bytes.
    public let byteCount: Int
    public let suffixCount: Int
    /// Suffixes are ordered by their first `cap` bytes. Longer terms are narrowed up to
    /// `cap` bytes and the remainder is verified directly, so results stay exact.
    public let cap: Int
    public let buildSeconds: Double
    /// Upper bound on suffix-array entries examined for one term. Beyond this the
    /// response is flagged approximate (only happens for very short, very common queries).
    public var scanCap = 250_000

    // Folded corpus: ASCII-lowercased, control bytes turned into spaces, documents
    // separated by a single 0 byte, padded with zeros at the end.
    let text: UnsafeMutablePointer<UInt8>
    let suffixes: UnsafeMutablePointer<UInt32>
    // Original bytes, same offsets as `text`, used for snippets and camelCase detection.
    let raw: [UInt8]
    let docStarts: [UInt32]
    let docEnds: [UInt32]
    let titleLens: [UInt32]
    let titles: [String]
    let references: [String]

    // MARK: Build

    public init(documents: [Document], cap requestedCap: Int = SearchIndex.defaultCap) {
        let t0 = DispatchTime.now().uptimeNanoseconds

        var total = 0
        for d in documents { total += d.title.utf8.count + d.body.utf8.count + 2 }
        precondition(total < Int(UInt32.max) - 64, "Corpus too large for 32-bit offsets")

        var folded = [UInt8]()
        var rawBytes = [UInt8]()
        folded.reserveCapacity(total + 16)
        rawBytes.reserveCapacity(total + 16)
        var starts = [UInt32](), ends = [UInt32](), tlens = [UInt32]()
        var titleList = [String](), refList = [String]()
        starts.reserveCapacity(documents.count)
        ends.reserveCapacity(documents.count)
        tlens.reserveCapacity(documents.count)

        for d in documents {
            starts.append(UInt32(folded.count))
            var tcount = 0
            for b in d.title.utf8 {
                folded.append(SearchIndex.fold(b))
                rawBytes.append(b == 0 ? 32 : b)
                tcount += 1
            }
            tlens.append(UInt32(tcount))
            folded.append(32)          // title / body separator
            rawBytes.append(32)
            for b in d.body.utf8 {
                folded.append(SearchIndex.fold(b))
                rawBytes.append(b == 0 ? 32 : b)
            }
            ends.append(UInt32(folded.count))
            folded.append(0)           // document separator
            rawBytes.append(0)
            titleList.append(d.title)
            refList.append(d.reference)
        }

        let n = folded.count
        let textPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: n + 16)
        textPtr.initialize(repeating: 0, count: n + 16)
        if n > 0 {
            folded.withUnsafeBufferPointer { src in
                _ = memcpy(textPtr, src.baseAddress!, n)
            }
        }

        let cap = max(8, requestedCap)
        let built = SearchIndex.buildSuffixArray(text: UnsafePointer(textPtr), n: n, cap: cap)

        self.text = textPtr
        self.suffixes = built.0
        self.suffixCount = built.1
        self.raw = rawBytes
        self.docStarts = starts
        self.docEnds = ends
        self.titleLens = tlens
        self.titles = titleList
        self.references = refList
        self.docCount = documents.count
        self.byteCount = n
        self.cap = cap
        self.buildSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
    }

    deinit {
        text.deallocate()
        suffixes.deallocate()
    }

    /// ASCII lowercase; every control byte (including NUL, tab, newline) becomes a space.
    /// Bytes >= 0x80 pass through untouched, so UTF-8 text of any script is searchable
    /// and offsets stay 1:1 with the original bytes.
    @inline(__always)
    static func fold(_ b: UInt8) -> UInt8 {
        if b < 32 { return 32 }
        if b >= 65 && b <= 90 { return b + 32 }
        return b
    }

    /// Bucket suffixes by their first two bytes (counting sort), then sort every bucket
    /// on its own core. Comparison uses the first `cap` bytes, ending at the first NUL.
    static func buildSuffixArray(text t: UnsafePointer<UInt8>, n: Int, cap: Int) -> (UnsafeMutablePointer<UInt32>, Int) {
        var counts = [Int](repeating: 0, count: 65537)
        var m = 0
        for i in 0..<n {
            let b0 = Int(t[i])
            if b0 == 0 { continue }
            let b1 = Int(t[i + 1])
            let bucket = (b0 << 8) | b1
            counts[bucket + 1] += 1
            m += 1
        }
        if m == 0 {
            return (UnsafeMutablePointer<UInt32>.allocate(capacity: 1), 0)
        }
        for i in 1...65536 { counts[i] += counts[i - 1] }
        let bounds = counts

        var entries = [SuffixKey](repeating: SuffixKey(key: 0, pos: 0), count: m)
        var cursor = bounds
        for i in 0..<n {
            if t[i] == 0 { continue }
            var key: UInt64 = 0
            var alive = true
            for j in 0..<8 {
                var v: UInt64 = 0
                if alive {
                    let x = t[i + j]
                    if x == 0 { alive = false } else { v = UInt64(x) }
                }
                key = (key << 8) | v
            }
            let bucket = Int(key >> 48)
            entries[cursor[bucket]] = SuffixKey(key: key, pos: UInt32(i))
            cursor[bucket] += 1
        }

        entries.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: 65536) { b in
                let lo = bounds[b], hi = bounds[b + 1]
                if hi - lo > 1 {
                    var slice = UnsafeMutableBufferPointer(start: base + lo, count: hi - lo)
                    slice.sort { x, y in SearchIndex.less(x, y, t, cap) }
                }
            }
        }

        let sa = UnsafeMutablePointer<UInt32>.allocate(capacity: m)
        for i in 0..<m { sa[i] = entries[i].pos }
        return (sa, m)
    }

    @inline(__always)
    static func less(_ a: SuffixKey, _ b: SuffixKey, _ t: UnsafePointer<UInt8>, _ cap: Int) -> Bool {
        if a.key != b.key { return a.key < b.key }
        if (a.key & 0xFF) == 0 { return false }      // both ended inside the first 8 bytes
        let pa = Int(a.pos), pb = Int(b.pos)
        var j = 8
        while j < cap {
            let x = t[pa + j], y = t[pb + j]
            if x != y { return x < y }
            if x == 0 { return false }
            j += 1
        }
        return false
    }

    // MARK: Interval narrowing

    /// All suffixes in `r` share their first `depth` bytes. Returns the sub-interval whose
    /// next byte is `c`. Two binary searches, nothing else.
    @inline(__always)
    func narrow(_ r: Range<Int>, depth: Int, byte c: UInt8) -> Range<Int> {
        var a = r.lowerBound
        var b = r.upperBound
        while a < b {
            let m = (a + b) >> 1
            if text[Int(suffixes[m]) + depth] < c { a = m + 1 } else { b = m }
        }
        let first = a
        b = r.upperBound
        while a < b {
            let m = (a + b) >> 1
            if text[Int(suffixes[m]) + depth] <= c { a = m + 1 } else { b = m }
        }
        return first..<a
    }

    /// For terms longer than `cap`: check the bytes the suffix array did not order.
    @inline(__always)
    func tailMatches(_ pos: Int, _ term: [UInt8]) -> Bool {
        var j = cap
        let m = term.count
        while j < m {
            if text[pos + j] != term[j] { return false }
            j += 1
        }
        return true
    }

    @inline(__always)
    func docIndex(forOffset pos: Int) -> Int {
        var lo = 0
        var hi = docStarts.count
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if Int(docStarts[mid]) <= pos { lo = mid } else { hi = mid }
        }
        return lo
    }

    // MARK: Text helpers

    @inline(__always)
    static func isWordByte(_ b: UInt8) -> Bool {
        return (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || b == 95 || b >= 128
    }

    /// Substring search inside the folded corpus (memchr + memcmp). Returns -1 if absent.
    func find(_ needle: [UInt8], from: Int, to: Int) -> Int {
        let m = needle.count
        if m == 0 || to - from < m { return -1 }
        let first = Int32(needle[0])
        let last = to - m
        var p = from
        let base = UnsafeRawPointer(text)
        return needle.withUnsafeBufferPointer { (nb: UnsafeBufferPointer<UInt8>) -> Int in
            let nptr = nb.baseAddress!
            while p <= last {
                guard let hit = memchr(base + p, first, last - p + 1) else { return -1 }
                let q = base.distance(to: UnsafeRawPointer(hit))
                if memcmp(base + q, nptr, m) == 0 { return q }
                p = q + 1
            }
            return -1
        }
    }

    // MARK: Document access

    public func title(of doc: Int) -> String { titles[doc] }
    public func reference(of doc: Int) -> String { references[doc] }

    public func body(of doc: Int) -> String {
        let ds = Int(docStarts[doc])
        let de = Int(docEnds[doc])
        let bodyStart = min(de, ds + Int(titleLens[doc]) + 1)
        return String(decoding: raw[bodyStart..<de], as: UTF8.self)
    }
}
