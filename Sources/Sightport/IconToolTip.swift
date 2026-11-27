import AppKit
import SwiftUI

struct IconToolTip: NSViewRepresentable {
    let title: String
    let detail: String?

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        guard view.title != title || view.detail != detail else { return }
        view.title = title
        view.detail = detail
        Presenter.shared.refresh(view)
    }

    // Tracking stays active over disabled SwiftUI buttons. All clicks reach the button underneath.
    final class Anchor: NSView {
        fileprivate var title = ""
        fileprivate var detail: String?

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { Presenter.shared.enter(self) }
        override func mouseExited(with event: NSEvent) { Presenter.shared.leave(self) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { Presenter.shared.leave(self) }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    @MainActor
    private final class Presenter: NSObject {
        static let shared = Presenter()

        private weak var anchor: Anchor?
        private var pending: Task<Void, Never>?
        private var monitor: Any?
        private var lastVisibleExit = -Double.infinity
        private let content = NSHostingController(rootView: Bubble(title: "", detail: nil))
        private lazy var panel: NSPanel = {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.isExcludedFromWindowsMenu = true
            panel.isReleasedWhenClosed = false
            panel.contentViewController = content
            panel.setAccessibilityElement(false)
            return panel
        }()

        func enter(_ view: Anchor) {
            guard let window = view.window, anchor !== view else { return }
            let immediate = panel.isVisible || ProcessInfo.processInfo.systemUptime - lastVisibleExit < 0.20
            dismiss()
            anchor = view
            let center = NotificationCenter.default
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                center.addObserver(self, selector: #selector(dismiss), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(dismiss), name: NSApplication.didResignActiveNotification, object: NSApp)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                self?.dismiss()
                return event
            }
            if immediate {
                show(view)
            } else {
                pending = Task { [weak view] in
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    if let view, anchor === view { show(view) }
                }
            }
        }

        func leave(_ view: Anchor) {
            guard anchor === view else { return }
            let wasVisible = panel.isVisible
            dismiss()
            if wasVisible { lastVisibleExit = ProcessInfo.processInfo.systemUptime }
        }

        func refresh(_ view: Anchor) {
            if anchor === view, panel.isVisible { show(view) }
        }

        @objc private func dismiss() {
            pending?.cancel()
            pending = nil
            anchor = nil
            lastVisibleExit = -.infinity
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        private func show(_ view: Anchor) {
            // A SwiftUI split pane can report its entire viewport as the anchor's visibleRect.
            let visibleButton = view.bounds.intersection(view.visibleRect)
            guard let window = view.window, window.isKeyWindow,
                  !view.isHiddenOrHasHiddenAncestor, !visibleButton.isEmpty else { dismiss(); return }
            let button = window.convertToScreen(view.convert(visibleButton, to: nil))
            let midpoint = CGPoint(x: button.midX, y: button.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) ?? window.screen else {
                dismiss()
                return
            }
            let available = screen.visibleFrame.insetBy(dx: 5, dy: 5)
            var bubble = Bubble(title: view.title, detail: view.detail)
            // Measure with the same wrapping width used when the panel draws its text.
            content.rootView = bubble
            let ideal = content.sizeThatFits(in: CGSize(width: 1024, height: 1024))
            let width = min(ceil(ideal.width) + 1, 264, available.width)
            bubble.width = width
            content.rootView = bubble
            let measured = content.sizeThatFits(in: CGSize(width: width, height: 1024))
            let size = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            let windowArea = available.intersection(window.frame.insetBy(dx: 5, dy: 0))
            let horizontal = windowArea.width >= size.width ? windowArea : available
            let x = min(max(horizontal.minX, button.midX - size.width / 2), horizontal.maxX - size.width)
            let below = button.minY - 3 - size.height
            bubble.pointsUp = below >= available.minY
            bubble.tipX = button.midX - x
            let y = bubble.pointsUp ? below : min(button.maxY + 3, available.maxY - size.height)
            content.rootView = bubble
            panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
        }
    }

    private struct Bubble: View {
        let title: String
        let detail: String?
        var width: CGFloat?
        var tipX: CGFloat = 18
        var pointsUp = true

        var body: some View {
            let outline = Outline(tipX: tipX, pointsUp: pointsUp)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(rgb: 0xC4CFC9))
                }
            }
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .padding(pointsUp ? .top : .bottom, 6)
            .frame(width: width.map { $0 - 2 }, alignment: .leading)
            .background(outline.fill(Color(rgb: 0x303836)))
            .overlay { outline.stroke(Color(rgb: 0x697B72), lineWidth: 1) }
            .padding(1)
            .accessibilityHidden(true)
        }
    }

    private struct Outline: Shape {
        let tipX: CGFloat
        let pointsUp: Bool

        func path(in rect: CGRect) -> Path {
            let body = CGRect(x: rect.minX, y: rect.minY + (pointsUp ? 6 : 0),
                              width: rect.width, height: rect.height - 6)
            let x = min(max(rect.minX + 12, tipX - 1), rect.maxX - 12)
            let base = pointsUp ? body.minY + 1 : body.maxY - 1
            let tip = Path { path in
                path.move(to: CGPoint(x: x - 7, y: base))
                path.addLine(to: CGPoint(x: x, y: pointsUp ? rect.minY : rect.maxY))
                path.addLine(to: CGPoint(x: x + 7, y: base))
                path.closeSubpath()
            }
            return Path(roundedRect: body, cornerRadius: 8).union(tip)
        }
    }
}
