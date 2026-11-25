import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

/// The session owns its emulator so switching drawer tabs preserves the screen and its scrollback.
@MainActor
final class PodTerminalScreen: @preconcurrency TerminalViewDelegate {
    fileprivate let terminal: TerminalView
    private(set) var columns = 80
    private(set) var rows = 24
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    init() {
        terminal = FocusablePodTerminal(frame: NSRect(x: 0, y: 0, width: 640, height: 320),
                                        font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        columns = terminal.getTerminal().cols
        rows = terminal.getTerminal().rows
        terminal.terminalDelegate = self
        terminal.nativeBackgroundColor = NSColor(Palette.sidebar)
        terminal.nativeForegroundColor = NSColor(Palette.ink)
        terminal.caretColor = NSColor(Palette.forest)
        terminal.setAccessibilityLabel("Pod terminal")
    }

    func receive(_ data: Data) {
        terminal.feed(byteArray: Array(data)[...])
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != columns || newRows != rows else { return }
        columns = newCols
        rows = newRows
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
}

private final class FocusablePodTerminal: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}

struct PodTerminalSurface: NSViewRepresentable {
    let screen: PodTerminalScreen

    func makeNSView(context: Context) -> TerminalView { screen.terminal }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
