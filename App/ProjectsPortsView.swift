// Projects & Ports: dev services grouped by project, with search and filters.
import SwiftUI
import PortmasterCore

struct ProjectsPortsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var filter: ServiceFilter = .all
    @State private var stopTarget: AppModel.StopTarget?

    enum ServiceFilter: String, CaseIterable, Identifiable {
        case all, active, quiet
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .active: "Active"
            case .quiet: "No recent CPU activity"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .sheet(item: $stopTarget) { target in
            StopSheet(target: target)
                .environmentObject(model)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by project, process, or port", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter services")
            Picker("Show", selection: $filter) {
                ForEach(ServiceFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Activity filter")
        }
        .padding(10)
        .cardBackground(cornerRadius: 8)
        .padding(12)
    }

    private var content: some View {
        let services = filtered(model.snapshot.services)
        if model.snapshot.services.isEmpty {
            return AnyView(EmptyStateView(
                symbol: "number",
                title: model.engine.collectionError == nil ? "No listening services" : "Port scan failed",
                detail: model.engine.collectionError == nil
                    ? "Nothing is listening on TCP ports right now. Start a dev server and it will appear here within a few seconds."
                    : (model.engine.collectionError ?? "The port scan did not complete. Existing entries may be stale."),
                buttonTitle: "Rescan",
                action: { model.engine.refreshNow() }
            ))
        }
        if services.isEmpty {
            return AnyView(EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No matches",
                detail: "No services match the current search or filter.",
                buttonTitle: "Clear filters",
                action: { query = ""; filter = .all }
            ))
        }
        return AnyView(groupedList(services))
    }

    private func filtered(_ services: [DevService]) -> [DevService] {
        services.filter { svc in
            switch filter {
            case .all: true
            case .active: !svc.activity.isQuiet
            case .quiet: svc.activity.isQuiet
            }
        }
        .filter { svc in
            guard !query.isEmpty else { return true }
            let q = query.lowercased()
            let project = svc.projectID.map { $0.lowercased() } ?? ""
            return svc.displayName.lowercased().contains(q)
                || project.contains(q)
                || svc.ports.contains { "\($0.port)".contains(q) }
                || (svc.runtimeLabel?.lowercased().contains(q) ?? false)
        }
    }

    private func groupedList(_ services: [DevService]) -> some View {
        let groups = Dictionary(grouping: services) { svc -> String in
            guard let pid = svc.projectID else { return "Unattributed" }
            return pid
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groups.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(groupTitle(key), systemImage: key == "Unattributed" ? "questionmark.folder" : "folder").font(.headline)
                            Spacer()
                            if key != "Unattributed" {
                                Button("Quit Project…") { stopTarget = model.projectStopTarget(key) }
                                    .disabled(model.prefs.fixtureMode)
                            }
                        }
                        ForEach(groups[key] ?? []) { svc in
                            ServiceRow(service: svc) {
                                stopTarget = model.processStopTarget(svc.process)
                            }
                        }
                    }
                    .padding(12)
                    .cardBackground()
                }
            }
            .padding(12)
        }
    }

    private func groupTitle(_ id: String) -> String {
        guard id != "Unattributed" else { return id }
        return id.components(separatedBy: "/").last ?? id
    }
}

/// One service row: port, process, runtime, project, activity, stop control.
struct ServiceRow: View {
    let service: DevService
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: String(format: ":%d", service.primaryPort ?? 0))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .frame(width: 64, alignment: .leading)
                .help(service.ports.map { ":\($0.port)" }.joined(separator: ", "))

            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let runtime = service.runtimeLabel {
                        Text(runtime)
                    }
                    Text("PID \(service.process.pid)")
                    if let started = service.process.startedAt {
                        Text("up \(Fmt.elapsed(since: started))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            activityLabel

            Button("Stop…", action: onStop)
                .controlSize(.small)
                .accessibilityLabel("Stop \(service.displayName), port \(service.primaryPort ?? 0)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var activityLabel: some View {
        switch service.activity {
        case .active:
            StateDot(color: .teal, word: "Active")
        case .quiet(let lookback):
            StateDot(color: .secondary.opacity(0.6), word: "No recent CPU activity")
                .help("No CPU activity observed for \(Fmt.elapsed(since: Date().addingTimeInterval(-lookback))). This is an observation, not a recommendation — the service may be idle by design.")
        }
    }
}
