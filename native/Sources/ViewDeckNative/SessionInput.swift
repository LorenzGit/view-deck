import AppKit
import ObjectiveC
import WebKit

private final class SessionMouseButtons: @unchecked Sendable {
    private let lock = NSLock()
    private var mask: UInt = 0
    func read() -> UInt { lock.lock(); defer { lock.unlock() }; return mask }
    func set(_ value: UInt) { lock.lock(); mask = value; lock.unlock() }
}

// Called only on the session host's main thread. These events go directly to
// its WebKit view, without moving the system pointer or activating a window.
@MainActor
final class SessionInput {
    private let preview: DevicePreviewView
    private var mouseButton: Int?
    private var lastPoint = CGPoint.zero
    private var lastViewport = CGSize.zero
    private var eventNumber = 0
    private var heldKeys: [String: (String, UInt16, NSEvent.ModifierFlags)] = [:]

    private static let buttons = SessionMouseButtons()
    private static var buttonStateInstalled = false

    init(preview: DevicePreviewView) {
        self.preview = preview
        // WebKit reads +[NSEvent pressedMouseButtons] when constructing DOM
        // events. That hardware state does not change for in-process events.
        // Override it only in this dedicated session helper, never in the GUI
        // process, so trusted drags have the correct buttons without posting
        // events to the user's desktop. See PlatformEventFactoryMac.mm.
        if !Self.buttonStateInstalled,
           let method = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)) {
            let state = Self.buttons
            let block: @convention(block) () -> UInt = { state.read() }
            method_setImplementation(method, imp_implementationWithBlock(block))
            Self.buttonStateInstalled = true
        }
    }

    var pressedKeys: [String] { heldKeys.keys.sorted() }

    func pointer(action: String, point: CGPoint, viewport: CGSize, button: Int = 0, clickCount: Int = 1) throws {
        guard Self.buttonStateInstalled,
              ["down", "move", "up"].contains(action), (0...2).contains(button),
              point.x.isFinite, point.y.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw SessionError.invalid("Invalid pointer action, button, or coordinates.")
        }
        let web = preview.sessionInputView
        guard let window = web.window else { throw SessionError.invalid("The preview has no input window.") }
        let local = CGPoint(x: point.x * web.bounds.width / viewport.width,
                            y: point.y * web.bounds.height / viewport.height)
        let location = web.convert(local, to: nil)
        let effectiveButton = action == "up" || action == "move" ? mouseButton ?? button : button
        let type: NSEvent.EventType
        switch (action, effectiveButton) {
        case ("down", 0): type = .leftMouseDown
        case ("down", 1): type = .rightMouseDown
        case ("down", _): type = .otherMouseDown
        case ("up", 0): type = .leftMouseUp
        case ("up", 1): type = .rightMouseUp
        case ("up", _): type = .otherMouseUp
        case ("move", _) where mouseButton == nil: type = .mouseMoved
        case ("move", 0): type = .leftMouseDragged
        case ("move", 1): type = .rightMouseDragged
        default: type = .otherMouseDragged
        }
        eventNumber += 1
        guard let baseEvent = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: eventNumber, clickCount: clickCount,
                                            pressure: action == "up" ? 0 : 1) else {
            throw SessionError.invalid("Could not create the native pointer event.")
        }
        // NSEvent's convenience constructor leaves movement deltas at zero.
        // Preserve them for canvas games that use movementX/movementY.
        let event: NSEvent
        if let cg = baseEvent.cgEvent {
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(effectiveButton))
            cg.setIntegerValueField(.mouseEventDeltaX, value: Int64(((point.x - lastPoint.x) * web.bounds.width / viewport.width).rounded()))
            cg.setIntegerValueField(.mouseEventDeltaY, value: Int64(((point.y - lastPoint.y) * web.bounds.height / viewport.height).rounded()))
            event = NSEvent(cgEvent: cg) ?? baseEvent
        } else { event = baseEvent }
        lastPoint = point
        lastViewport = viewport
        if action == "down" { mouseButton = button; window.makeFirstResponder(web) }
        Self.buttons.set(action == "up" ? 0 : mouseButton.map { UInt(1) << $0 } ?? 0)
        switch type {
        case .leftMouseDown: web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        case .leftMouseDragged: web.mouseDragged(with: event)
        case .rightMouseDown: web.rightMouseDown(with: event)
        case .rightMouseUp: web.rightMouseUp(with: event)
        case .rightMouseDragged: web.rightMouseDragged(with: event)
        case .otherMouseDown: web.otherMouseDown(with: event)
        case .otherMouseUp: web.otherMouseUp(with: event)
        case .otherMouseDragged: web.otherMouseDragged(with: event)
        default: web.mouseMoved(with: event)
        }
        if action == "up" { mouseButton = nil }
    }

    func key(_ key: String, action: String, modifiers: String = "", keyCode: Int? = nil) throws {
        guard ["down", "up"].contains(action) else { throw SessionError.invalid("Key action must be down, up, or press.") }
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers.split(separator: ",").map({ $0.lowercased() }) {
            switch modifier {
            case "shift": flags.insert(.shift)
            case "control", "ctrl": flags.insert(.control)
            case "option", "alt": flags.insert(.option)
            case "command", "meta", "cmd": flags.insert(.command)
            default: throw SessionError.invalid("Unknown keyboard modifier: \(modifier)")
            }
        }
        let named: [String: (String, UInt16)] = [
            "ArrowLeft": ("\u{F702}", 123), "ArrowRight": ("\u{F703}", 124),
            "ArrowDown": ("\u{F701}", 125), "ArrowUp": ("\u{F700}", 126),
            "Enter": ("\r", 36), "Return": ("\r", 36), "Tab": ("\t", 48),
            "Escape": ("\u{1b}", 53), "Backspace": ("\u{7f}", 51),
            "Delete": ("\u{F728}", 117), "Space": (" ", 49), " ": (" ", 49),
            "Home": ("\u{F729}", 115), "End": ("\u{F72B}", 119),
            "PageUp": ("\u{F72C}", 116), "PageDown": ("\u{F72D}", 121)
        ]
        let codes: [String: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
            "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,
            "6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
            "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,
            ";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50]
        let characters = named[key]?.0 ?? key
        let inferredCode = named[key]?.1 ?? codes[key.lowercased()]
        guard let code = keyCode.flatMap(UInt16.init(exactly:)) ?? inferredCode else {
            throw SessionError.invalid("Unsupported key. Use --key-code for a native key code, or session type for text.")
        }
        let web = preview.sessionInputView
        guard let window = web.window else { throw SessionError.invalid("The preview has no input window.") }
        window.makeFirstResponder(web)
        let repeating = heldKeys[key] != nil
        if action == "down" { heldKeys[key] = (characters, code, flags) }
        let value = action == "up" ? heldKeys.removeValue(forKey: key) ?? (characters, code, flags) : (characters, code, flags)
        guard let event = NSEvent.keyEvent(with: action == "down" ? .keyDown : .keyUp,
                                          location: .zero, modifierFlags: value.2,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: value.0, charactersIgnoringModifiers: value.0,
                                          isARepeat: repeating && action == "down", keyCode: value.1) else {
            throw SessionError.invalid("Could not create the native key event.")
        }
        if action == "down" { web.keyDown(with: event) } else { web.keyUp(with: event) }
    }

    func type(_ text: String) throws {
        let web = preview.sessionInputView
        guard web.window?.makeFirstResponder(web) == true,
              let client = web as? NSTextInputClient else {
            throw SessionError(code: "native_input_unavailable", message: "WebKit text input is unavailable.")
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func releaseAll() {
        for keyName in Array(heldKeys.keys) { try? key(keyName, action: "up") }
        if mouseButton != nil {
            try? pointer(action: "up", point: lastPoint, viewport: lastViewport)
        }
    }
}
