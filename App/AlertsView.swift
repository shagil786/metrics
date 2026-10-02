// Alerts: what's acting up, in plain language. Observations, not verdicts.
import SwiftUI
import PortmasterCore

struct AlertsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.alerts.isEmpty {
                EmptyStateView(
                    symbol: "bell.badge.slash",
                    title: "Nothing is acting up",
                    detail: "Portmaster watches for sustained CPU, memory growth, and heavy disk or network activity. Notification Center delivery requires permission in Settings → Alerts.",
                    buttonTitle: model.prefs.alertsEnabled ? "Alert Settings" : "Enable Alerts in Settings",
                    action: { AppDelegate.shared?.openSettingsWindow() }
                )
            } else {
                List(model.alerts) { alert in
                    AlertRow(alert: alert)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }

            Divider()
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Watches CPU, memory growth, disk writes and downloads. Alerts appear at most once per app per hour; Notification Center requires permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
    }
}

struct AlertRow: View {
    let alert: ActingUpAlert
    private var glyph: (String, Color) { OverviewView.alertGlyph(alert.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph.0)
                .font(.title3)
                .foregroundStyle(glyph.1)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(alert.headline)
                    .font(.headline)
                Text(alert.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(alert.at, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.headline). \(alert.detail)")
    }
}
