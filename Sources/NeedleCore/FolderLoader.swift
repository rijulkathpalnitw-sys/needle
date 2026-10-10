import Foundation

/// Reads text-like files under a folder into `Document`s.
public enum FolderLoader {

    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "java", "kt",
        "go", "rs", "rb", "py", "js", "jsx", "ts", "tsx", "json", "yaml", "yml", "toml", "xml", "html", "css",
        "scss", "sh", "zsh", "bash", "sql", "csv", "tsv", "log", "tex", "ini", "cfg", "conf", "plist", "strings",
    ]

    static let skipDirectories: Set<String> = [
        "node_modules", ".git", "build", "DerivedData", "Pods", ".build", "venv", ".venv",
        "__pycache__", "dist", "target", "Carthage",
    ]

    public static func load(
        from root: URL,
        maxFileBytes: Int = 4_000_000,
        maxTotalBytes: Int = 600_000_000
    ) -> [Document] {
        var docs: [Document] = []
        var total = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path

        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skipDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let size = values?.fileSize ?? 0
            if size == 0 || size > maxFileBytes { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if data.prefix(4096).contains(0) { continue }      // looks binary
            total += data.count
            if total > maxTotalBytes { break }

            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(rootPath) {
                rel.removeFirst(rootPath.count)
                while rel.hasPrefix("/") { rel.removeFirst() }
            }
            docs.append(Document(title: rel, body: String(decoding: data, as: UTF8.self), reference: url.path))
        }
        return docs
    }
}
