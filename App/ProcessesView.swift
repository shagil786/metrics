// Processes: searchable, sortable, grouped by app; detail shows path and args.
import SwiftUI
import PortmasterCore

struct ProcessesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var sort: SortField = .cpu
    @State private var ascending = false
    @State private var groupByApp = true
    @State private var detailRow: ProcessRow?
    @State private var stopTarget: AppModel.StopTarget?
    @State private var autoOpenedSheet = false

    enum SortField: String, CaseIterable, Identifiable {
        case name, cpu, memory, elapsed
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            processList
        }
        // PORTMASTER_OPEN_APP="<name>": auto-present the Inside App sheet for
        // the first matching rollup once data arrives (debug/UI-testing
        // affordance — lets the sheet be captured without UI scripting).
        .onReceive(model.engine.$latest) { snap in
            guard !autoOpenedSheet,
                  let name = ProcessInfo.processInfo.environment["PORTMASTER_OPEN_APP"] else { return }
            guard let app = snap.rollups.first(where: {
                $0.displayName.lowercased() == name.lowercased()
            }) else { return }
            autoOpenedSheet = true
            // Defer off the attach pass: @Published delivers synchronously on
            // subscribe and mutating @State during attach crashes
            // NSHostingView (see WindowCpuDetail note).
            Task { @MainActor in model.selectedMenuApp = app }
        }
        .sheet(item: $detailRow) { row in
            ProcessDetailSheet(row: row)
                .environmentObject(model)
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
            TextField("Search processes", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search processes")
            Picker("Sort", selection: $sort) {
                ForEach(SortField.allCases) { f in
                    Text(f.rawValue.capitalized).tag(f)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Sort by")
            Picker("Group", selection: $groupByApp) {
                Text("By app").tag(true)
                Text("All processes").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("Grouping")
            Button {
                ascending.toggle()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(ascending ? "Ascending order" : "Descending order")
        }
        .padding(10)
        .cardBackground(cornerRadius: 8)
        .padding(12)
    }

    private var processList: some View {
        if groupByApp {
            return AnyView(rollupList)
        }
        let rows = filtered()
        if rows.isEmpty {
            return AnyView(EmptyStateView(
                symbol: "list.bullet",
                title: query.isEmpty ? "Gathering process data" : "No matches",
                detail: query.isEmpty
                    ? "The first sweep is completing. This fills in within a couple of seconds."
                    : "No process matches \"\(query)\".",
                buttonTitle: query.isEmpty ? "Refresh" : "Clear search",
                action: { query = "" ; model.engine.refreshNow() }
            ))
        }
        return AnyView(
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    headerRow
                    ForEach(rows) { row in
                        ProcessLine(row: row) {
                            detailRow = row
                        } onStop: {
                            stopTarget = model.processStopTarget(row)
                        }
                        Divider().opacity(0.35)
                    }
                }
                .padding(.horizontal, 12)
            }
        )
    }

    private var headerRow: some View {
        HStack {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 64, alignment: .trailing)
            Text("Memory").frame(width: 76, alignment: .trailing)
            Text("Uptime").frame(width: 70, alignment: .trailing)
            Text("").frame(width: 60)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    /// Vitals-style rollup: one row per app with helpers counted underneath.
    /// Honors the same sort/direction controls as the flat list, and search
    /// matches helper names too (a helper query finds its host app).
    private var rollupList: some View {
        let q = query.lowercased()
        var apps = model.snapshot.rollups
        if !q.isEmpty {
            apps = apps.filter { rollup in
                rollup.displayName.lowercased().contains(q)
                    || rollup.memberNames.contains { $0.lowercased().contains(q) }
                    || "\(rollup.pidCount)".contains(q)
            }
        }
        apps.sort { a, b in
            let result: Bool
            switch sort {
            case .name:
                result = a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .cpu:
                result = a.totalCPU < b.totalCPU
            case .memory:
                result = a.totalMemory < b.totalMemory
            case .elapsed:
                result = a.processes.map { $0.startedAt ?? .distantPast }.min() ?? .distantPast
                    < b.processes.map { $0.startedAt ?? .distantPast }.min() ?? .distantPast
            }
            return ascending ? result : !result
        }
        if apps.isEmpty {
            return AnyView(EmptyStateView(
                symbol: "square.stack.3d.up",
                title: query.isEmpty ? "Gathering process data" : "No matches",
                detail: query.isEmpty
                    ? "The first sweep is completing. This fills in within a couple of seconds."
                    : "No app matches \"\(query)\".",
                buttonTitle: query.isEmpty ? "Refresh" : "Clear search",
                action: { query = "" ; model.engine.refreshNow() }
            ))
        }
        return AnyView(
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        AppRollupLine(rollup: app) {
                            // App-level detail: the "what's inside" breakdown,
                            // not one arbitrary member process.
                            model.selectedMenuApp = app
                        } onStop: {
                            stopTarget = model.stopTarget(name: app.displayName, project: nil, members: ConfirmedStopPlan.ordered(app.processes))
                        }
                        Divider().opacity(0.35)
                    }
                }
                .padding(.horizontal, 12)
            }
        )
    }

    private func filtered() -> [ProcessRow] {
        let q = query.lowercased()
        var rows = model.snapshot.processes.filter { row in
            guard !q.isEmpty else { return true }
            return row.displayName.lowercased().contains(q)
                || (row.projectID?.lowercased().contains(q) ?? false)
                || "\(row.pid)".contains(q)
        }
        rows.sort { a, b in
            let cmp: ComparisonResult
            switch sort {
            case .name: cmp = a.displayName.localizedCompare(b.displayName)
            case .cpu:
                let av = a.cpuPercent ?? -1, bv = b.cpuPercent ?? -1
                cmp = av == bv ? .orderedSame : (av < bv ? .orderedAscending : .orderedDescending)
            case .memory:
                let av = a.memoryBytes ?? 0, bv = b.memoryBytes ?? 0
                cmp = av == bv ? .orderedSame : (av < bv ? .orderedAscending : .orderedDescending)
            case .elapsed:
                let av = a.startedAt ?? .distantPast, bv = b.startedAt ?? .distantPast
                cmp = av == bv ? .orderedSame : (av < bv ? .orderedAscending : .orderedDescending)
            }
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
        return rows
    }
}

/// One process line with app/project attribution and stop entry point.
struct ProcessLine: View {
    @EnvironmentObject private var model: AppModel
    let row: ProcessRow
    let onDetails: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.isAppBundle ? "app" : "terminal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("PID \(row.pid)")
                    if let proj = row.projectID {
                        Text("·")
                        Text(proj.components(separatedBy: "/").last ?? proj)
                            .help(proj)
                    } else {
                        Text("·")
                        Text("Unattributed")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            CPUBar(percent: model.processCPUValue(row.cpuPercent ?? 0) ?? 0, tint: Theme.stateColor(cpuPercent: row.cpuPercent ?? 0))
                .frame(width: 110)
            Text(model.cpuText(row.cpuPercent))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(Fmt.bytes(row.memoryBytes))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Text(Fmt.elapsed(since: row.startedAt))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Button("Details") { onDetails() }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Stop…") { onStop() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onDetails() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(row.displayName), PID \(row.pid), CPU \(model.cpuText(row.cpuPercent)), memory \(Fmt.bytes(row.memoryBytes))"
        )
    }
}

/// Details sheet: full path and args, only shown on explicit open. On-device.
struct ProcessDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: ProcessRow
    @State private var path: String?
    @State private var args: [String]?
    @State private var cwd: String?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(row.displayName)
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("PID").foregroundStyle(.secondary)
                    Text("\(row.pid)").monospacedDigit()
                }
                GridRow {
                    Text("Parent PID").foregroundStyle(.secondary)
                    Text(row.parentPid.map { "\($0)" } ?? "Unknown").monospacedDigit()
                }
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Text(row.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
                }
                GridRow {
                    Text("CPU").foregroundStyle(.secondary)
                    Text(model.cpuText(row.cpuPercent)).monospacedDigit()
                }
                GridRow {
                    Text("Memory").foregroundStyle(.secondary)
                    Text(Fmt.bytes(row.memoryBytes)).monospacedDigit()
                }
                if let cwd {
                    GridRow {
                        Text("Working dir").foregroundStyle(.secondary)
                        Text(cwd).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)

            Divider()

            detailBlock(title: "Executable path", value: path)
            detailBlock(title: "Arguments", value: args?.joined(separator: " "))

            if loadFailed {
                Text("Path and arguments are unavailable for this process (system restrictions or the process exited).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 480, height: 400)
        .task { load() }
    }

    @ViewBuilder
    private func detailBlock(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text("Not available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        guard let collector = model.processCollector else {
            loadFailed = true
            return
        }
        path = collector.executablePath(pid: row.pid)
        args = collector.commandArguments(pid: row.pid)
        cwd = collector.workingDirectory(pid: row.pid)
        if path == nil && args == nil && cwd == nil { loadFailed = true }
    }
}
