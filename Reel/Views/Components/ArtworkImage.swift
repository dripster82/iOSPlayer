import SwiftUI
import Library

/// Async artwork with a deterministic gradient placeholder (PLAN.md §11.5) so grids never show empty boxes.
struct ArtworkImage: View {
    let url: URL?
    let title: String
    var aspect: CGFloat = 2 / 3
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    /// The box's longest side in pixels, measured once laid out; the decode is sized to it.
    @State private var maxPixel = 0

    var body: some View {
        // The box is sized by "fit" from whichever dimension the caller fixes; the artwork fills that box
        // and is clipped to it. With "fill" the box itself grew to the container (a card inside a
        // full-screen overlay produced a screen-sized placeholder).
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                ZStack {
                    Placeholder(title: title)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(GeometryReader { g in
                Color.clear.onAppear { measure(g.size) }.onChange(of: g.size) { _, size in measure(size) }
            })
        .task(id: "\(url?.absoluteString ?? "")|\(ImageLoader.bucket(maxPixel))") {
            guard let url, maxPixel > 0 else { image = nil; return }
            // A larger bucket only re-decodes; the smaller picture stays up meanwhile instead of flashing the placeholder.
            if let next = await ImageLoader.shared.image(for: url, maxPixel: maxPixel) { image = next } else { image = nil }
        }
    }

    private func measure(_ size: CGSize) {
        let px = Int((max(size.width, size.height) * UIScreen.main.scale).rounded(.up))
        // Only grow: a cell that shrinks a few points during a layout pass need not re-decode.
        if px > maxPixel { maxPixel = px }
    }

    struct Placeholder: View {
        let title: String
        var body: some View {
            let (a, b) = Palette.colors(for: title)
            LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Text(String(title.first.map(String.init) ?? "?").uppercased())
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 6)
                }
        }
    }
}

enum Palette {
    private static let pairs: [(Color, Color)] = [
        (Color(hex: 0x6b3fa0), Color(hex: 0xc74b6d)), (Color(hex: 0x1f6f8b), Color(hex: 0x4bb3a5)),
        (Color(hex: 0x8b2f1f), Color(hex: 0xd9833b)), (Color(hex: 0x2f4858), Color(hex: 0x86a873)),
        (Color(hex: 0x5c3d2e), Color(hex: 0xb85c38)), (Color(hex: 0x1b3a4b), Color(hex: 0x5b7db1)),
        (Color(hex: 0x4a2545), Color(hex: 0xb65f8a)), (Color(hex: 0x2d5a27), Color(hex: 0x9ac46b)),
        (Color(hex: 0x3b2f63), Color(hex: 0x7a6fd0)), (Color(hex: 0x6a1b1b), Color(hex: 0xc23b3b)),
    ]
    static func colors(for title: String) -> (Color, Color) {
        var h: UInt32 = 0
        for c in title.utf8 { h = h &* 31 &+ UInt32(c) }
        return pairs[Int(h % UInt32(pairs.count))]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
