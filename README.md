# Needle

A substring-first search engine in Swift, plus a SwiftUI app on top of it.

## What's different

Most search engines tokenize text into words and keep an inverted index (word → documents).
That makes "swift" fast and "wift" impossible.

Needle has **no tokenizer and no inverted index**. It builds one **suffix array** over the whole
corpus, so every byte offset is a searchable entry point:

- `urlsess` finds `URLSessionConfiguration`; `serprof` finds `fetchUserProfile`
- `0xdead`, `v2.14`, `@example.com`, `"user pro"` (phrase with a space) all work
- works for any UTF-8 text, including CJK, with no language-specific analysis

**Typing is incremental.** Suffixes matching `swif` are always a sub-interval of those matching `swi`.
Each search session remembers the interval per prefix, so a new character costs two small binary
searches inside the previous interval, and backspace is a lookup. The app draws this as the bar
strip under the search field: candidates left after each keystroke.

Search flow: narrow interval(s) → rarest term walks its interval, aggregating per document →
other terms verified inside candidate docs (AND) → rank → snippets for the top hits only.

Ranking: log term frequency, title match, word-start (camelCase aware), whole-word, light length
normalization.

Honest limits: an index is built up front (parallel sort, roughly seconds per 10s of MB, not persisted
yet); 32-bit offsets cap the corpus at ~4 GB; no typo tolerance; ASCII-only case folding; very short common
queries like `e` are flagged approximate after `scanCap` (250k) occurrences.

## Layout

    Sources/NeedleCore    engine (SearchIndex.swift, Search.swift, DemoCorpus.swift, FolderLoader.swift)
    Sources/NeedleBench   latency benchmark vs. linear scan
    Sources/NeedleApp     SwiftUI app (macOS target)
    Tests/NeedleCoreTests XCTest suite (brute-force comparisons, incremental typing, phrases, CJK)

## Run

    swift test
    swift run -c release NeedleBench --docs 20000
    swift run -c release NeedleBench --folder ~/Projects/some-repo
    swift run -c release NeedleApp          # macOS 13+

In Xcode: open `Package.swift`, pick the `NeedleApp` scheme, run. For iOS, create an iOS app project,
add this folder as a local package dependency (library `NeedleCore`), and copy the files from
`Sources/NeedleApp` into it (remove the `@main` duplicate if needed).

In the app: the Index menu switches the demo corpus or indexes any folder of text/code files.

## Verification status

The Swift code was written in an environment without a Swift toolchain, so it has **not been
compiled or run**. The core algorithm (capped suffix sort, narrowing with prefix reuse, tail check for
long terms, multi-term AND) was ported to Python and checked against brute force on ~67k randomized
queries, including incremental typing and backspacing. Expect to possibly fix a small compile error or two
on first build; `swift test` is the first thing to run.
