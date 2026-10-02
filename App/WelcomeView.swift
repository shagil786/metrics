import SwiftUI

struct WelcomeView: View {
    let finish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Welcome to Portmaster", systemImage: "waveform.path.ecg").font(.largeTitle.bold())
            Text("See what's busy, what's listening, and what your Mac can report.").font(.title3)
            Label("Your menu bar stays live. Click a reading for the dropdown, or open the full window for details and history.", systemImage: "menubar.rectangle")
            Label("The read-only dashboard requires no permission prompts. Audio control and the microphone meter request access only when you enable them.", systemImage: "hand.raised")
            Label("History stays on this Mac. Stop actions show the affected processes and require your confirmation.", systemImage: "internaldrive")
            Text("Arrange tabs, cards and menu-bar readings in Settings → Layout. Shortcuts and display units are in General. Unavailable measurements appear as —.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Get Started", action: finish).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
