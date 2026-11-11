import Foundation

/// A lightweight list of machines shared with the Home Screen widget and
/// App Intents (which may run outside the app process) through the App Group
/// container.
public enum MachineCatalog {
    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var osType: GuestOSType

        public init(id: UUID, name: String, osType: GuestOSType) {
            self.id = id
            self.name = name
            self.osType = osType
        }

        public init(_ config: VMConfiguration) {
            self.init(id: config.id, name: config.name, osType: config.osType)
        }
    }

    /// Info.plist key holding the App Group identifier (set from project.yml).
    public static let appGroupInfoKey = "PVMAppGroup"

    /// URL scheme used by widgets and shortcuts: `pocketvm://start?id=<uuid>`.
    public static let urlScheme = "pocketvm"

    public static func startURL(for id: UUID) -> URL {
        URL(string: "\(urlScheme)://start?id=\(id.uuidString)")!
    }

    /// Parses `pocketvm://start?id=<uuid>` (also accepts `pocketvm://start/<uuid>`).
    public static func machineID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == "start" else { return nil }
        if let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value {
            return UUID(uuidString: item)
        }
        return UUID(uuidString: url.lastPathComponent)
    }

    public static var fileURL: URL? {
        let fm = FileManager.default
        #if canImport(Darwin)
        if let group = Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
           !group.isEmpty,
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appendingPathComponent("machines-catalog.json")
        }
        #endif
        // Without an App Group (e.g. signing without the capability) the
        // catalog still works inside the app process.
        return (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("machines-catalog.json")
    }

    public static func write(_ entries: [Entry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> [Entry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
