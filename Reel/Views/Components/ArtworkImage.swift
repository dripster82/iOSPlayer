import SwiftUI
import Library

/// Async artwork with a deterministic gradient placeholder (PLAN.md §11.5) so grids never show empty boxes.
struct ArtworkImage: View {
    let url: URL?
    let title: String
    var aspect: CGFloat = 2 / 3
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Placeholder(title: title)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .aspectRatio(aspect, contentMode: .fill)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ImageLoader.shared.image(for: url)
        }
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
