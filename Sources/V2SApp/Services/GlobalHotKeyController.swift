import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyController {
    enum Action {
        case followUp
        case ask
        case switchMode
    }

    private enum HotKeyID: UInt32 {
        case followUp = 1
        case ask = 2
        case switchMode = 3
    }

    // Carbon virtual key codes for alphanumeric keys (ANSI layout)
    static let keyCodeMap: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
        "k": 0x28, "n": 0x2D, "m": 0x2E,
    ]

    static let availableKeys: [String] = [
        "a","b","c","d","e","f","g","h","i","j","k","l","m",
        "n","o","p","q","r","s","t","u","v","w","x","y","z",
        "0","1","2","3","4","5","6","7","8","9"
    ]

    private let onAction: (Action) -> Void
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        installEventHandler()
    }

    deinit {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func update(followUp: HotKeyBinding, ask: HotKeyBinding, switchMode: HotKeyBinding) {
        unregisterAll()
        registerBinding(followUp, id: .followUp)
        registerBinding(ask, id: .ask)
        registerBinding(switchMode, id: .switchMode)
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in controller.handle(hotKeyID: hotKeyID) }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }

    private func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
    }

    private func registerBinding(_ binding: HotKeyBinding, id: HotKeyID) {
        let key = binding.key.lowercased()
        guard let keyCode = Self.keyCodeMap[key] else { return }
        let mods = Self.carbonModifiers(binding)
        register(keyCode: keyCode, modifiers: mods, id: id)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: HotKeyID) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x56325320), id: id.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRefs.append(ref) }
    }

    private static func carbonModifiers(_ binding: HotKeyBinding) -> UInt32 {
        var mods: UInt32 = 0
        if binding.useCommand { mods |= UInt32(cmdKey) }
        if binding.useOption  { mods |= UInt32(optionKey) }
        if binding.useControl { mods |= UInt32(controlKey) }
        if binding.useShift   { mods |= UInt32(shiftKey) }
        return mods
    }

    private func handle(hotKeyID: EventHotKeyID) {
        switch HotKeyID(rawValue: hotKeyID.id) {
        case .followUp:   onAction(.followUp)
        case .ask:        onAction(.ask)
        case .switchMode: onAction(.switchMode)
        case nil:         break
        }
    }
}
