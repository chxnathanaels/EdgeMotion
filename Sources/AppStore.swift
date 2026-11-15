import AppKit
import Combine

struct AppItem: Identifiable, Hashable {
    let id: String          // bundle path
    let name: String
    let url: URL
}

/// Finds installed apps through the Spotlight index (live: new/removed apps appear automatically),
/// with a plain folder scan as a fallback, and caches their icons.
final class AppStore: ObservableObject {
    @Published private(set) var apps: [AppItem] = []

    private let query = NSMetadataQuery()
    private let iconCache = NSCache<NSString, NSImage>()
    private var scanned: [String: AppItem] = [:]
    private var indexed: [String: AppItem] = [:]
    private var hiddenObserver: AnyCancellable?

    private let scopes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/Applications/Utilities", home + "/Applications"]
    }()

    var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenApps"); rebuild() }
    }

    init() {
        iconCache.countLimit = 600
        scanFolders()
        rebuild()

        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        query.searchScopes = scopes
        NotificationCenter.default.addObserver(self, selector: #selector(queryChanged),
                                               name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(queryChanged),
                                               name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
    }

    @objc private func queryChanged(_ note: Notification) {
        query.disableUpdates()
        var found: [String: AppItem] = [:]
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let app = makeItem(path) else { continue }
            found[path] = app
        }
        query.enableUpdates()
        indexed = found
        rebuild()
    }

    private func scanFolders() {
        let fm = FileManager.default
        var found: [String: AppItem] = [:]
        for dir in scopes {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(n)
                if let app = makeItem(path) { found[path] = app }
            }
        }
        scanned = found
    }

    private func makeItem(_ path: String) -> AppItem? {
        // skip helper apps nested inside other app bundles
        let appParts = path.components(separatedBy: "/").filter { $0.hasSuffix(".app") }
        guard appParts.count == 1 else { return nil }
        if path == Bundle.main.bundlePath { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return AppItem(id: path, name: name, url: URL(fileURLWithPath: path))
    }

    private func rebuild() {
        let hide = hidden
        var all = scanned
        for (k, v) in indexed { all[k] = v }
        let list = all.values
            .filter { !hide.contains($0.id) && FileManager.default.fileExists(atPath: $0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != apps { apps = list }
    }

    func refresh() { scanFolders(); rebuild() }

    func icon(for item: AppItem) -> NSImage {
        if let img = iconCache.object(forKey: item.id as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: item.id)
        img.size = NSSize(width: 256, height: 256)
        iconCache.setObject(img, forKey: item.id as NSString)
        return img
    }

    /// Load icons ahead of time in small batches so the first open is instant.
    func prewarm() {
        let items = apps
        var i = 0
        func step() {
            let end = min(i + 12, items.count)
            while i < end { _ = icon(for: items[i]); i += 1 }
            if i < items.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: step) }
        }
        DispatchQueue.main.async(execute: step)
    }

    /// Search: name prefix matches first, then word prefixes, then anywhere.
    func search(_ q: String) -> [AppItem] {
        let needle = q.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return apps }
        var scored: [(Int, AppItem)] = []
        for a in apps {
            let hay = a.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if hay.hasPrefix(needle) { scored.append((0, a)) }
            else if hay.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { scored.append((1, a)) }
            else if hay.contains(needle) { scored.append((2, a)) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending }
            .map { $0.1 }
    }
}
