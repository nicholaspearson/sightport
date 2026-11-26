import SwiftUI

extension Color {
    init(rgb value: UInt32) {
        self.init(.sRGB, red: Double(value >> 16 & 255) / 255,
                  green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}

enum Palette {
    static let canvas = Color(rgb: 0x202325)
    static let surface = Color(rgb: 0x1C1F21)
    static let sidebar = Color(rgb: 0x191C1D)
    static let raised = Color(rgb: 0x282C2E)
    static let rowHover = Color(rgb: 0x313538)
    static let line = Color(rgb: 0x373C3D)
    static let ink = Color(rgb: 0xECF0EC)
    static let muted = Color(rgb: 0xA8B2AC)
    static let forest = Color(rgb: 0x9ADDB6)
    static let selection = Color(rgb: 0x2F443A)
}

struct IconAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(hovered ? Palette.raised : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Palette.muted)
        .onHover { hovered = $0 }.help(title).accessibilityLabel(title)
    }
}

struct TableRowHover: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.attachToRow() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class Anchor: NSView {
        private weak var row: NSTableRowView?
        private var area: NSTrackingArea?
        private var originalColor: NSColor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToRow()
        }

        func attachToRow() {
            var ancestor = superview
            while ancestor != nil && !(ancestor is NSTableRowView) { ancestor = ancestor?.superview }
            let next = window == nil ? nil : ancestor as? NSTableRowView
            guard row !== next else { return }
            detach()
            guard let next else { return }
            // Track the row itself so column gaps, links and controls share one hover.
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
            next.addTrackingArea(area)
            row = next
            self.area = area
        }

        func detach() {
            restoreColor()
            if let area { row?.removeTrackingArea(area) }
            area = nil
            row = nil
        }

        override func mouseEntered(with event: NSEvent) {
            guard event.trackingArea === area, let row, originalColor == nil else { return }
            originalColor = row.backgroundColor
            row.backgroundColor = NSColor(Palette.rowHover)
        }

        override func mouseExited(with event: NSEvent) {
            if event.trackingArea === area { restoreColor() }
        }

        private func restoreColor() {
            if let originalColor { row?.backgroundColor = originalColor }
            originalColor = nil
        }
    }
}
