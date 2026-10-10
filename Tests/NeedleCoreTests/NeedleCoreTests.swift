import XCTest
@testable import NeedleCore

final class NeedleCoreTests: XCTestCase {

    // Small, hand-written corpus where the right answers are obvious.
    func smallIndex() -> SearchIndex {
        SearchIndex(documents: [
            Document(title: "Networking notes", body: "fetchUserProfile loads the profile from URLSessionConfiguration cache."),
            Document(title: "Recipes", body: "Whisk the eggs. Fold in flour. Bake until golden."),
            Document(title: "Release", body: "Tagged v2.14.7 with hash 0xdeadbeef and contact ada.lovelace@example.com"),
            Document(title: "Profile page", body: "A user profile shows a name, a photo and recent activity."),
        ])
    }

    func ids(_ r: SearchResponse) -> Set<Int> { Set(r.hits.map { $0.id }) }

    func testSubstringInsideWord() {
        let idx = smallIndex()
        var s = SearchSession()
        let r = idx.search("serprof", limit: 10, session: &s)      // fetchUserProfile
        XCTAssertEqual(ids(r), [0])
        let r2 = idx.search("deadbe", limit: 10, session: &s)
        XCTAssertEqual(ids(r2), [2])
        let r3 = idx.search("@example.com", limit: 10, session: &s)
        XCTAssertEqual(ids(r3), [2])
    }

    func testCaseInsensitive() {
        let idx = smallIndex()
        var s = SearchSession()
        XCTAssertEqual(ids(idx.search("URLSESSION", limit: 10, session: &s)), [0])
        XCTAssertEqual(ids(idx.search("urlsession", limit: 10, session: &s)), [0])
    }

    func testPhraseWithSpaces() {
        let idx = smallIndex()
        var s = SearchSession()
        XCTAssertEqual(ids(idx.search("\"fold in\"", limit: 10, session: &s)), [1])
        XCTAssertTrue(idx.search("\"in fold\"", limit: 10, session: &s).hits.isEmpty)
    }

    func testMultiTermIsAnd() {
        let idx = smallIndex()
        var s = SearchSession()
        // "profile" is in docs 0 and 3, "photo" only in 3.
        XCTAssertEqual(ids(idx.search("profile", limit: 10, session: &s)), [0, 3])
        XCTAssertEqual(ids(idx.search("profile photo", limit: 10, session: &s)), [3])
        XCTAssertTrue(idx.search("profile eggs", limit: 10, session: &s).hits.isEmpty)
    }

    func testTitleMatchOutranksBodyMatch() {
        let idx = SearchIndex(documents: [
            Document(title: "Misc", body: "orbit orbit orbit orbit"),
            Document(title: "Orbit", body: "short"),
        ])
        var s = SearchSession()
        let r = idx.search("orbit", limit: 10, session: &s)
        XCTAssertEqual(r.hits.first?.id, 1)
    }

    func testNoMatchAndEmptyQuery() {
        let idx = smallIndex()
        var s = SearchSession()
        XCTAssertTrue(idx.search("zzzzqq", limit: 10, session: &s).hits.isEmpty)
        XCTAssertTrue(idx.search("   ", limit: 10, session: &s).hits.isEmpty)
        XCTAssertTrue(idx.search("", limit: 10, session: &s).hits.isEmpty)
    }

    func testSnippetContainsMatch() {
        let idx = smallIndex()
        var s = SearchSession()
        let r = idx.search("golden", limit: 10, session: &s)
        XCTAssertTrue(r.hits.first?.snippet.lowercased().contains("golden") ?? false)
    }

    func testNonASCIIText() {
        let idx = SearchIndex(documents: [Document(title: "日本語", body: "検索エンジンは速い。Café déjà vu.")])
        var s = SearchSession()
        XCTAssertEqual(ids(idx.search("エンジン", limit: 5, session: &s)), [0])
        XCTAssertEqual(ids(idx.search("café", limit: 5, session: &s)), [0])
    }

    // MARK: Randomised comparison against a linear scan

    func testSingleTermMatchesBruteForce() {
        let idx = SearchIndex(documents: DemoCorpus.generate(count: 400, seed: 11))
        var s = SearchSession()
        let probes = ["a", "th", "pro", "file", "0x", "e100", "v2.", "ser", "api/v", "ing", ". ", "example.com", "zq"]
        for q in probes {
            let r = idx.search(q, limit: 5, session: &s)
            let b = idx.bruteForceCount(q)
            XCTAssertEqual(r.occurrences, b.occurrences, "occurrences for \(q)")
            XCTAssertEqual(r.matchingDocs, b.documents, "documents for \(q)")
        }
    }

    func testTermsLongerThanCapStayExact() {
        // cap is clamped to a minimum of 8, so a 30-byte term exercises the tail check.
        let idx = SearchIndex(documents: DemoCorpus.generate(count: 300, seed: 5), cap: 8)
        XCTAssertEqual(idx.cap, 8)
        var s = SearchSession()
        let body = idx.body(of: 17)
        let start = body.index(body.startIndex, offsetBy: 5)
        let end = body.index(start, offsetBy: 30)
        let q = String(body[start..<end]).trimmingCharacters(in: .whitespaces)
        let phrase = "\"" + q + "\""
        let r = idx.search(phrase, limit: 5, session: &s)
        let b = idx.bruteForceCount(phrase)
        XCTAssertGreaterThan(b.occurrences, 0)
        XCTAssertEqual(r.occurrences, b.occurrences)
        XCTAssertEqual(r.matchingDocs, b.documents)
    }

    func testIncrementalTypingEqualsFreshSearch() {
        let idx = SearchIndex(documents: DemoCorpus.generate(count: 300, seed: 3))
        var typing = SearchSession()
        let word = "usersession"
        var typed = ""
        for ch in word {
            typed.append(ch)
            let a = idx.search(typed, limit: 5, session: &typing)
            var fresh = SearchSession()
            let b = idx.search(typed, limit: 5, session: &fresh)
            XCTAssertEqual(a.occurrences, b.occurrences, "after typing \(typed)")
            XCTAssertEqual(a.matchingDocs, b.matchingDocs)
        }
        // Backspace all the way, then retype something else.
        while !typed.isEmpty {
            typed.removeLast()
            let a = idx.search(typed, limit: 5, session: &typing)
            var fresh = SearchSession()
            let b = idx.search(typed, limit: 5, session: &fresh)
            XCTAssertEqual(a.occurrences, b.occurrences, "after deleting to \(typed)")
        }
    }

    func testMultiTermAgainstNaiveDocumentScan() {
        let docs = DemoCorpus.generate(count: 250, seed: 9)
        let idx = SearchIndex(documents: docs)
        var s = SearchSession()
        let queries = [["user", "cache"], ["fetch", "0x"], ["the", "bridge", "and"]]
        for terms in queries {
            let r = idx.search(terms.joined(separator: " "), limit: 10_000, session: &s)
            var expected = Set<Int>()
            for (i, d) in docs.enumerated() {
                let hay = (d.title + " " + d.body).lowercased()
                    .replacingOccurrences(of: "\n", with: " ")
                if terms.allSatisfy({ hay.contains($0) }) { expected.insert(i) }
            }
            XCTAssertEqual(ids(r), expected, "terms \(terms)")
        }
    }
}
