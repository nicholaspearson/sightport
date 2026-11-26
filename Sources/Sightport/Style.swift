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

struct WorkbenchProgressStyle: ProgressViewStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        if configuration.fractionCompleted == nil {
            VStack(spacing: 4) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { frame in
                    let turn = reduceMotion ? 0 : frame.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    let stroke = StrokeStyle(lineWidth: max(1.5, diameter / 8), lineCap: .round)
                    Circle()
                        .strokeBorder(Palette.muted.opacity(0.32), lineWidth: stroke.lineWidth)
                        .overlay {
                            Circle().inset(by: stroke.lineWidth / 2)
                                .trim(from: 0, to: 0.68)
                                .stroke(Palette.forest, style: stroke)
                                .rotationEffect(.degrees(turn * 360 - 90))
                        }
                }
                .frame(width: diameter, height: diameter)
                configuration.label
                configuration.currentValueLabel
            }
            .foregroundStyle(Palette.ink)
            .accessibilityRepresentation { ProgressView(configuration).progressViewStyle(.circular) }
        } else {
            ProgressView(configuration).progressViewStyle(.automatic)
        }
    }

    private var diameter: CGFloat {
        switch controlSize {
        case .mini: 10
        case .small: 16
        case .regular: 20
        case .large: 32
        case .extraLarge: 40
        @unknown default: 20
        }
    }
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

struct InspectorDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .modifier(DisclosureHeaderFeedback())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 6)
            }
        }
    }
}

struct DisclosureHeaderFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var handPushed = false

    func body(content: Content) -> some View {
        content
            .background(hovered && isEnabled ? Palette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
                showHand(inside && isEnabled)
            }
            .onChange(of: isEnabled) { _, enabled in showHand(hovered && enabled) }
            .onDisappear {
                hovered = false
                showHand(false)
            }
    }

    private func showHand(_ show: Bool) {
        guard handPushed != show else { return }
        handPushed = show
        if show { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
