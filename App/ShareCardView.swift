import SwiftUI
import PortmasterCore

/// A 1200×630 picture of one moment on one machine, for posting.
///
/// Everything here is drawn from a `ShareCardContent` that was resolved and
/// formatted before this view existed, so nothing on the card invents a
/// figure, re-decides a unit, or picks its own ordering. The view's only job
/// is layout.
///
/// Deliberately sparse: a machine name, two big numbers, and the five apps
/// that hold the most memory. No process counts in the headline, no charts, no
/// alerts — a card that tries to show everything at this size shows nothing
/// legibly. The one thing it does insist on is the timestamp, because a card
/// showing only a date would let someone post a two-week-old reading as
/// current.
struct ShareCardView: View {
    let content: ShareCardContent

    /// Always light. See `OverviewView.exportShareCard` for why the app's
    /// adaptive theme is not used here.
    private let canvas = Color(red: 0.98, green: 0.98, blue: 0.99)
    private let card = Color.white
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.12)
    private let muted = Color(red: 0.42, green: 0.42, blue: 0.47)
    private let accent = Color(red: 0.15, green: 0.55, blue: 0.52)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The middle grows to fill, and its content sits at the bottom of
            // that space. Top-anchoring it instead left a dead band above the
            // footer, so the card read as unfinished at a glance.
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                HStack(alignment: .top, spacing: 24) {
                    headline
                    appList
                }
                .padding(.horizontal, 40)
                Spacer(minLength: 24)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.machineName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
            if !content.subtitle.isEmpty {
                Text(content.subtitle)
                    .font(.system(size: 18))
                    .foregroundStyle(muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 24)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 20) {
            figure(
                value: content.memoryUsed ?? "—",
                caption: content.memoryCaption
            )
            figure(value: content.cpu, caption: "CPU")
        }
        .frame(width: 380, alignment: .leading)
    }

    private func figure(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 62, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 17))
                .foregroundStyle(muted)
                .lineLimit(1)
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TOP APPS BY MEMORY")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(muted)
                .padding(.bottom, 12)
            if content.apps.isEmpty {
                Text("No app rollups recorded yet")
                    .font(.system(size: 17))
                    .foregroundStyle(muted)
            } else {
                ForEach(Array(content.apps.enumerated()), id: \.offset) { index, app in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(muted)
                            .frame(width: 20, alignment: .leading)
                        Text(app.name)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text("\(app.processCount) processes")
                            .font(.system(size: 15))
                            .foregroundStyle(muted)
                            .lineLimit(1)
                        Text(app.memory)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 11)
                    if index < content.apps.count - 1 {
                        Divider().overlay(muted.opacity(0.25))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(card, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(content.timestampText)
                .font(.system(size: 16))
                .foregroundStyle(muted)
            Spacer()
            Text("Portmaster")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ink)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 30)
    }
}
