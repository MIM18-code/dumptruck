import AppKit
import SwiftUI

/// Tracks selection over the SwiftUI grid. Buttons keep their own hit targets.
struct ConnectedShelfInteraction: NSViewRepresentable {
    let paths: [String]
    let frames: [String: CGRect]
    @Binding var selection: Set<String>

    func makeNSView(context: Context) -> ShelfSelectionView {
        ShelfSelectionView()
    }

    func updateNSView(_ view: ShelfSelectionView, context: Context) {
        view.paths = paths
        view.frames = frames
        view.selection = selection
        view.readSelection = { selection }
        view.changed = { selection = $0 }
    }
}

final class ShelfSelectionView: NSView {
    var paths: [String] = []
    var frames: [String: CGRect] = [:]
    var selection: Set<String> = []
    var changed: (Set<String>) -> Void = { _ in }
    var readSelection: () -> Set<String> = { [] }
    private var marquee: CGRect?
    private var gestureStart: NSPoint?
    private var gestureSelection = Set<String>()
    private var gestureExtending = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            return nil
        }
        let point = convert(point, from: superview)
        guard bounds.contains(point) else { return nil }
        if frames.values.contains(where: { $0.contains(point) }) { return nil }
        return self
    }

    private func publish(_ paths: Set<String>) {
        selection = paths
        changed(paths)
    }

    override func mouseDown(with event: NSEvent) {
        selection = readSelection()
        window?.makeFirstResponder(self)
        gestureStart = convert(event.locationInWindow, from: nil)
        gestureSelection = selection
        gestureExtending = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        if !gestureExtending { publish([]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = gestureStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        marquee = rect
        needsDisplay = true
        let intersecting = Set(paths.filter { frames[$0]?.intersects(rect) == true })
        publish(gestureExtending ? gestureSelection.union(intersecting) : intersecting)
    }

    override func mouseUp(with event: NSEvent) {
        gestureStart = nil
        marquee = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            gestureStart = nil
            marquee = nil
            needsDisplay = true
            publish([])
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            publish(Set(paths))
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let marquee else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: marquee).fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: marquee.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}

struct ConnectedShelfFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
