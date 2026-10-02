import AppKit
import Carbon
import Combine
import PortmasterCore

@MainActor
final class GlobalShortcuts: ObservableObject {
    @Published private(set) var error: String?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var subscription: AnyCancellable?
    private var previous: [KeyboardShortcutPreference] = []
    init(model: AppModel) {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x504D4854 else { return OSStatus(eventNotHandledErr) }
            let action = id.id
            DispatchQueue.main.async {
                let delegate = AppDelegate.shared
                if action == 1 { delegate?.openMainWindow() }
                else if action == 2 { delegate?.statusItems?.toggle() }
            }
            return noErr
        }, 1, &type, nil, &handler)
        subscription = model.$prefs.sink { [weak self] prefs in
            self?.configure([prefs.presentation.windowShortcut, prefs.presentation.panelShortcut])
        }
    }
    private func configure(_ shortcuts: [KeyboardShortcutPreference]) {
        guard shortcuts != previous else { return }; previous = shortcuts
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); error = nil
        guard handler != nil else { error = "macOS could not install the keyboard shortcut handler."; return }
        var seen = Set<String>()
        for (index, shortcut) in shortcuts.enumerated() where shortcut.enabled {
            guard shortcut.valid, let code = Self.codes[shortcut.key] else { error = "Choose a key with Command, Option or Control."; continue }
            guard seen.insert(shortcut.label).inserted else { error = "The window and dropdown need different shortcuts."; continue }
            var flags: UInt32 = 0
            if shortcut.command { flags |= UInt32(cmdKey) }; if shortcut.option { flags |= UInt32(optionKey) }
            if shortcut.control { flags |= UInt32(controlKey) }; if shortcut.shift { flags |= UInt32(shiftKey) }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, flags, EventHotKeyID(signature: 0x504D4854, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { error = "\(shortcut.label) is unavailable (macOS \(status)). Choose another shortcut." }
        }
    }
    // Hardware virtual key codes avoid needing Accessibility or a key-event monitor.
    static let codes: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46,"F1":122,"F2":120,"F3":99,"F4":118,"F5":96,"F6":97,"F7":98,"F8":100,"F9":101,"F10":109,"F11":103,"F12":111]
    deinit { refs.forEach { UnregisterEventHotKey($0) }; if let handler { RemoveEventHandler(handler) } }
}
