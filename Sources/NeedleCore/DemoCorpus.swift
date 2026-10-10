import Foundation

/// Deterministic synthetic corpus: prose mixed with the kind of strings ordinary word-based
/// search engines handle badly (camelCase identifiers, hex ids, versions, e-mail addresses,
/// URL paths, error codes). Useful for demos, tests and benchmarks.
public enum DemoCorpus {

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static let words: [String] = [
        "orbit", "lantern", "harbor", "protocol", "signal", "meadow", "cipher", "thread", "falcon", "quartz",
        "network", "ledger", "compass", "garden", "engine", "voltage", "marble", "river", "summit", "archive",
        "cluster", "pattern", "window", "bridge", "kernel", "pigment", "canvas", "forest", "turbine", "anchor",
        "monitor", "journal", "crystal", "delta", "ember", "fabric", "glacier", "horizon", "island", "jungle",
        "keystone", "lattice", "mosaic", "nebula", "outpost", "prairie", "quiver", "ribbon", "saddle", "tundra",
        "update", "vector", "walnut", "yellow", "zephyr", "budget", "camera", "dinner", "editor", "format",
        "guitar", "helmet", "icon", "jacket", "kitchen", "laptop", "market", "notebook", "oven", "pencil",
        "queue", "rocket", "school", "ticket", "umbrella", "valley", "weather", "xylophone", "yogurt", "zipper",
        "was", "the", "and", "with", "from", "into", "over", "under", "about", "after", "before", "during",
        "quickly", "slowly", "carefully", "often", "rarely", "always", "never", "sometimes", "usually", "finally",
        "builds", "repairs", "measures", "records", "removes", "installs", "rewrites", "inspects", "compiles", "ships",
        "reliable", "ancient", "modern", "silent", "bright", "fragile", "portable", "efficient", "granular", "tolerant",
    ]

    static let codeParts: [String] = [
        "fetch", "user", "profile", "cache", "session", "config", "url", "request", "response", "handler",
        "buffer", "stream", "token", "parse", "render", "layout", "store", "index", "query", "result",
        "queue", "worker", "manager", "factory", "builder", "reader", "writer", "image", "view", "model",
    ]

    static let names: [String] = [
        "ada", "grace", "alan", "linus", "margaret", "dennis", "barbara", "edsger", "radia", "ken",
        "lovelace", "hopper", "turing", "torvalds", "hamilton", "ritchie", "liskov", "dijkstra", "perlman", "thompson",
    ]

    static func camel(_ rng: inout SplitMix64, capitalizeFirst: Bool) -> String {
        let n = 2 + rng.below(2)
        var out = ""
        for k in 0..<n {
            let part = codeParts[rng.below(codeParts.count)]
            if k == 0 && !capitalizeFirst { out += part } else { out += part.prefix(1).uppercased() + part.dropFirst() }
        }
        return out
    }

    static func hex(_ rng: inout SplitMix64, _ digits: Int) -> String {
        let table = Array("0123456789abcdef")
        var s = ""
        for _ in 0..<digits { s.append(table[rng.below(16)]) }
        return s
    }

    static func token(_ rng: inout SplitMix64) -> String {
        switch rng.below(24) {
        case 0: return camel(&rng, capitalizeFirst: false)
        case 1: return camel(&rng, capitalizeFirst: true)
        case 2: return "0x" + hex(&rng, 8)
        case 3: return "v\(rng.below(5)).\(rng.below(30)).\(rng.below(12))"
        case 4: return "\(names[rng.below(10)]).\(names[10 + rng.below(10)])@example.com"
        case 5: return "/api/v\(1 + rng.below(3))/\(codeParts[rng.below(codeParts.count)])/\(words[rng.below(40)])"
        case 6: return "E\(1000 + rng.below(9000))"
        case 7: return codeParts[rng.below(codeParts.count)] + "_" + codeParts[rng.below(codeParts.count)]
        default: return words[rng.below(words.count)]
        }
    }

    public static func generate(count: Int, seed: UInt64 = 42) -> [Document] {
        var rng = SplitMix64(state: seed)
        var docs: [Document] = []
        docs.reserveCapacity(count)
        for i in 0..<count {
            let title = "\(words[rng.below(words.count)].capitalized) \(words[rng.below(words.count)]) \(camel(&rng, capitalizeFirst: true))"
            var body = ""
            let sentences = 3 + rng.below(9)
            for _ in 0..<sentences {
                let len = 6 + rng.below(9)
                for w in 0..<len {
                    let t = token(&rng)
                    body += (w == 0) ? t.prefix(1).uppercased() + t.dropFirst() : t
                    body += (w == len - 1) ? ". " : " "
                }
                if rng.below(5) == 0 { body += "\n" }
            }
            docs.append(Document(title: title, body: body, reference: "demo/\(i).txt"))
        }
        return docs
    }
}
