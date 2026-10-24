import SwiftUI
import SafariServices
import Library
import Metadata

/// "Trailer" on a film or show page: TMDb's best YouTube trailer, opened in an in-app Safari sheet.
/// Hidden until a trailer is known to exist.
struct TrailerButton: View {
    @EnvironmentObject private var settings: AppSettings
    let item: MediaItem
    @State private var trailers: [TMDbVideo] = []
    @State private var showing: URL?

    var body: some View {
        Group {
            if let first = trailers.first, let url = first.youTubeURL {
                if trailers.count > 1 {
                    Menu {
                        ForEach(trailers.prefix(6)) { t in Button(t.name) { showing = t.youTubeURL } }
                    } label: { Label("Trailer", systemImage: "play.rectangle") } primaryAction: { showing = url }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { showing = url } label: { Label("Trailer", systemImage: "play.rectangle") }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .task(id: item.itemKey) {
            guard let tmdb = settings.tmdb, let id = item.tmdbID, item.kind != .episode else { return }
            trailers = (try? await tmdb.trailers(id: id, isShow: item.kind == .show)) ?? []
        }
        .sheet(item: $showing) { url in SafariView(url: url).ignoresSafeArea() }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
