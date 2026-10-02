import SwiftUI
import PortmasterCore

struct LayoutEditor: View {
    let title: String
    let catalog: [(String, String)]
    @Binding var layout: LayoutOrder
    var keepOne = true
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            let ordered = layout.resolved(catalog.map(\.0))
            ForEach(Array(ordered.enumerated()), id: \.element) { index, id in
                HStack {
                    Toggle(catalog.first { $0.0 == id }?.1 ?? id, isOn: Binding(
                        get: { !layout.hidden.contains(id) },
                        set: { visible in
                            if visible { layout.hidden.remove(id) }
                            else if !keepOne || layout.visible(catalog.map(\.0)).count > 1 { layout.hidden.insert(id) }
                        }))
                        .disabled(keepOne && !layout.hidden.contains(id) && layout.visible(catalog.map(\.0)).count == 1)
                        .help(keepOne && layout.visible(catalog.map(\.0)).count == 1 ? "At least one item must stay visible" : "Show or hide this item")
                    Spacer()
                    Button { move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).accessibilityLabel("Move \(id) earlier")
                    Button { move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == ordered.count - 1).accessibilityLabel("Move \(id) later")
                }
            }
        }
    }
    private func move(_ id: String, by delta: Int) {
        var order = layout.resolved(catalog.map(\.0)); guard let index = order.firstIndex(of: id), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta); layout.order = order
    }
}

/// Shared ordered section host keeps existing card implementations intact.
struct ArrangedSections: View {
    @EnvironmentObject private var model: AppModel
    let scope: String
    let sections: [(id: String, title: String, view: AnyView)]
    var body: some View {
        let visible = (model.prefs.presentation.sections[scope] ?? LayoutOrder()).visible(sections.map(\.id))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visible, id: \.self) { id in
                if let section = sections.first(where: { $0.id == id }) { section.view }
            }
        }
    }
}

struct ArrangeButton: View {
    @EnvironmentObject private var model: AppModel
    let scope: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Label("Arrange", systemImage: "slider.horizontal.3") }
            .popover(isPresented: $showing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if scope == "overview" {
                            LayoutEditor(title: "Overview cards", catalog: LayoutCatalog.overview, layout: $model.prefs.presentation.overviewCards)
                        } else if let catalog = LayoutCatalog.sections[scope] {
                            LayoutEditor(title: "\(scope.capitalized) sections", catalog: catalog, layout: Binding(
                                get: { model.prefs.presentation.sections[scope] ?? LayoutOrder() },
                                set: { model.prefs.presentation.sections[scope] = $0 }))
                        } else {
                            Text("This tab has one content section. Its visibility and position are controlled in Layout.")
                        }
                        Button("Done") { showing = false }
                    }.padding(16)
                }.frame(width: 310, height: scope == "overview" ? 480 : 250)
            }
    }
}

enum LayoutCatalog {
    static let overview: [(String, String)] = [("cpu","CPU"),("memory","Memory"),("gpu","GPU"),("disk","Disk"),("network","Network"),("power","Power"),("hardware","Hardware"),("thermal","Heat context"),("memoryType","Memory by type"),("memoryApps","Memory by app"),("powerApps","CPU by app"),("sound","Volume mixer"),("bluetooth","Bluetooth")]
    static let panelTiles = [("cpu","CPU"),("memory","Memory"),("network","Network"),("disk","Disk"),("gpu","GPU"),("power","Power / Battery")]
    static let sections: [String: [(String, String)]] = [
        "cpu": standard, "memory": standard, "disk": standard, "network": standard,
        "gpu": [("hero","Usage and chart"),("stats","Statistics"),("about","About")],
        "power": [("power","Power source and details"),("awake","Keeping awake")],
        "containers": [("stats","Statistics"),("history","History chart"),("containers","Container list")],
        "audio": [("output","Output volume"),("input","Input activity and meter"),("apps","App mixer")]
    ]
    static let standard = [("hero","Reading and chart"),("stats","Statistics"),("apps","Apps")]
}
