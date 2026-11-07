// A system-wide shortcut through Carbon RegisterEventHotKey: works in any app (Zoom in full screen)
// without the Accessibility permission. Registered only while recording, so it never steals ⌃⌥I otherwise.

import Carbon.HIToolbox
import Foundation

@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: () -> Void
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private var id: UInt32 = 0

    /// ⌃⌥I: "important".
    static func important(_ action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey), action: action)
    }

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    func setActive(_ on: Bool) { on ? register() : unregister() }

    private func register() {
        guard ref == nil else { return }
        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let hkID = EventHotKeyID(signature: OSType(0x535A_564E), id: id)  // "SZVN"
        if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) != noErr {
            NSLog("Sozvon: ⌃⌥I is taken by another app")
            unregister()  // no handler left behind: the next recording tries again from scratch
        }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        Self.actions[id] = nil
    }
}
