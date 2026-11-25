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
