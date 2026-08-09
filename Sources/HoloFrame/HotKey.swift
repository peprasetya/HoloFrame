//
//  HotKey.swift — a system-wide keyboard shortcut.
//
//  Carbon's RegisterEventHotKey is used rather than an NSEvent global monitor because it
//  needs no Accessibility permission and works while HoloFrame is a background
//  (LSUIElement) app that never takes focus.
//

import AppKit
import Carbon.HIToolbox

final class HotKey {

    // Carbon modifier masks, for callers that would rather not import Carbon.
    static let command = UInt32(cmdKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
    static let shift = UInt32(shiftKey)

    static let keyR = UInt32(kVK_ANSI_R)

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var reference: EventHotKeyRef?
    private let identifier: UInt32

    /// Returns nil if the combination is already taken by another application.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        identifier = Self.nextID
        Self.nextID += 1
        Self.actions[identifier] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x484F_4C4F), id: identifier)  // 'HOLO'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            Self.actions[identifier] = nil
            return nil
        }
        self.reference = reference
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.actions[identifier] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &pressed)
            guard status == noErr else { return status }
            HotKey.actions[pressed.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
