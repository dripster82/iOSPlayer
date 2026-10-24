import SwiftUI
import MediaCore
import Library
import Metadata

/// TMDb's recommendations for a title, with the ones in the library in colour and tappable and the
/// rest dimmed, so the row doubles as "what you have" and "what you might get".
struct MoreLikeThisRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    let item: MediaItem
    @State private var recs: [TMDbClient.Recommendation] = []
    @State private var owned: [Int: MediaItem] = [:]

    var body: some View {
        if !recs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("More like this").font(.headline); Spacer(); Text("\(owned.count) of \(recs.count) in your library").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(recs) { r in
                            if let mine = owned[r.id] {
                                NavigationLink(value: mine.itemKey) { card(r, owned: true) }.buttonStyle(.plain)
                            } else {
                                card(r, owned: false)
                            }
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }

    private func card(_ r: TMDbClient.Recommendation, owned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkImage(url: ArtworkURL.poster(r.posterPath), title: r.title).frame(width: 100)
                .saturation(owned ? 1 : 0.3).opacity(owned ? 1 : 0.6)
                .overlay(alignment: .topTrailing) { if owned { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(6) } }
            Text(r.title).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 100, alignment: .leading)
            Text(r.year.map(String.init) ?? "").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

extension MoreLikeThisRow {
    func loading() -> some View {
        task(id: item.itemKey) {
            guard let tmdb = settings.tmdb, let id = item.tmdbID, item.kind != .episode else { return }
            recs = (try? await tmdb.recommendations(id: id, isShow: item.kind == .show)) ?? []
            owned = library.items(tmdbIDs: Set(recs.map(\.id)))
        }
    }
}
