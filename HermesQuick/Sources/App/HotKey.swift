import Carbon.HIToolbox
import Foundation

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, controlOptionSpace, commandShiftSpace, optionCommandH

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .commandShiftSpace: "⇧⌘ Space"
        case .optionCommandH: "⌥⌘ H"
        }
    }

    var keyCode: UInt32 { self == .optionCommandH ? UInt32(kVK_ANSI_H) : UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .optionCommandH: UInt32(optionKey | cmdKey)
        }
    }
}

/// System-wide hotkey via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(_ preset: HotKeyPreset, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        Self.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.instances[id]?.action() } }
            return noErr
        }, 1, &spec, nil, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x4845_524D), id: id) // 'HERM'
        RegisterEventHotKey(preset.keyCode, preset.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    func invalidate() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        Self.instances[id] = nil
    }
}
