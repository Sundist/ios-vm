import AppIntents
import SwiftUI
import VMCore
import WidgetKit

/// Widget configuration: which virtual machine this widget starts.
struct SelectMachineIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Virtual Machine"
    static let description = IntentDescription("The virtual machine this widget starts.")

    @Parameter(title: "Virtual Machine")
    var machine: VirtualMachineEntity?

    init() {}
}

struct MachineEntry: TimelineEntry {
    let date: Date
    let machine: VirtualMachineEntity?
    var isMissing = false
}

struct MachineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MachineEntry {
        MachineEntry(date: .now, machine: .placeholder)
    }

    func snapshot(for configuration: SelectMachineIntent, in context: Context) async -> MachineEntry {
        entry(for: configuration, preview: context.isPreview)
    }

    func timeline(for configuration: SelectMachineIntent, in context: Context) async -> Timeline<MachineEntry> {
        Timeline(entries: [entry(for: configuration, preview: false)], policy: .never)
    }

    private func entry(for configuration: SelectMachineIntent, preview: Bool) -> MachineEntry {
        let catalog = MachineCatalog.read()
        if let chosen = configuration.machine {
            // Pick up renames; flag machines that were deleted.
            if let fresh = catalog.first(where: { $0.id == chosen.id }) {
                return MachineEntry(date: .now, machine: VirtualMachineEntity(fresh))
            }
            return MachineEntry(date: .now, machine: chosen, isMissing: true)
        }
        if let first = catalog.first {
            return MachineEntry(date: .now, machine: VirtualMachineEntity(first))
        }
        return MachineEntry(date: .now, machine: preview ? .placeholder : nil)
    }
}

struct MachineWidgetView: View {
    let entry: MachineEntry

    var body: some View {
        if let machine = entry.machine {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: machine.osType.symbolName)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(machine.osType.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11))
                Spacer(minLength: 0)
                Text(machine.name)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Label(entry.isMissing ? "Deleted" : "Start", systemImage: entry.isMissing ? "xmark.circle" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(MachineCatalog.startURL(for: machine.id))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.title)
                Text("Create a machine in PocketVM")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct MachineWidget: Widget {
    let kind = "MachineWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectMachineIntent.self, provider: MachineProvider()) { entry in
            MachineWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Virtual Machine")
        .description("Start a virtual machine straight from the Home Screen.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct PocketVMWidgetBundle: WidgetBundle {
    var body: some Widget {
        MachineWidget()
    }
}
