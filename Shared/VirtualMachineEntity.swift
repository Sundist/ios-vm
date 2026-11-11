import AppIntents
import SwiftUI
import VMCore

/// A virtual machine as seen by Shortcuts, Siri and widgets. Compiled into
/// both the app and the widget extension; data comes from `MachineCatalog`.
struct VirtualMachineEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine")
    static let defaultQuery = VirtualMachineQuery()

    var id: UUID
    var name: String
    var osType: GuestOSType

    init(id: UUID, name: String, osType: GuestOSType) {
        self.id = id
        self.name = name
        self.osType = osType
    }

    init(_ entry: MachineCatalog.Entry) {
        self.init(id: entry.id, name: entry.name, osType: entry.osType)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(osType.shortName)",
            image: .init(systemName: osType.symbolName))
    }

    static let placeholder = VirtualMachineEntity(id: UUID(), name: "Windows XP", osType: .windowsNT)
}

struct VirtualMachineQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [VirtualMachineEntity] {
        MachineCatalog.read()
            .filter { identifiers.contains($0.id) }
            .map(VirtualMachineEntity.init)
    }

    func entities(matching string: String) async throws -> [VirtualMachineEntity] {
        MachineCatalog.read()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(VirtualMachineEntity.init)
    }

    func suggestedEntities() async throws -> [VirtualMachineEntity] {
        MachineCatalog.read().map(VirtualMachineEntity.init)
    }
}

extension GuestOSType {
    /// Icon colour shared by the app and the widget.
    var accentColor: Color {
        switch colorName {
        case "blue": return .blue
        case "orange": return .orange
        case "gray": return .gray
        case "purple": return .purple
        case "indigo": return .indigo
        case "green": return .green
        default: return .teal
        }
    }
}
