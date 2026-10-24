import SwiftUI
import MediaCore
import Library
import Metadata

/// Edit artwork: every poster, backdrop and logo the active sources hold for a title (TMDb always,
/// fanart.tv when keyed), or for a collection the posters of its titles. Tap one to use it; the
/// choice is stored on the item or collection and synced.
struct ArtworkPickerView: View {
    enum Target { case item(MediaItem), collection(MediaCollection) }
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let target: Target

    enum Slot: String, CaseIterable { case poster = "Poster", backdrop = "Backdrop", logo = "Logo" }
    struct Candidate: Identifiable, Hashable { var url: URL; var source: String; var id: String { url.absoluteString } }

    @State private var slot: Slot = .poster
    @State private var tmdb: [Slot: [Candidate]] = [:]
    @State private var fanart: [Slot: [Candidate]] = [:]
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .item = target {
                        Picker("", selection: $slot) { ForEach(Slot.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(.horizontal)
                    }
                    currentRow
                    if loading { HStack { ProgressView(); Text("Fetching artwork…").font(.footnote).foregroundStyle(.secondary) }.padding(.horizontal) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                    if case .collection(let c) = target {
                        section("Posters of its titles", c.itemKeys.compactMap { library.item($0)?.posterURL(size: .detail) }.map { Candidate(url: $0, source: "library") })
                    } else {
                        section("TMDb", tmdb[slot] ?? [])
                        if settings.fanart != nil { section("fanart.tv", fanart[slot] ?? []) }
                        else if slot != .poster { Text("Add a fanart.tv key in Settings for more logos and backgrounds.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                    }
                }.padding(.vertical)
            }
            .navigationTitle("Edit artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
    }

    /// What is in use now, with a way back to the automatic choice.
    private var currentRow: some View {
        HStack(spacing: 12) {
            if let url = currentURL { ArtworkImage(url: url, title: "current", aspect: slotAspect, cornerRadius: 8).frame(height: 70) }
            VStack(alignment: .leading, spacing: 4) {
                Text(hasOverride ? "Your choice" : "Automatic").font(.subheadline.weight(.semibold))
                if hasOverride { Button("Use automatic") { setOverride(nil) }.font(.footnote) }
                else { Text("Tap any picture below to use it instead.").font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
        }.padding(.horizontal)
    }

    private func section(_ title: String, _ candidates: [Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(candidates.count)").font(.headline).padding(.horizontal)
            if candidates.isEmpty, !loading { Text("Nothing here.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: slot == .poster ? 100 : 150), spacing: 10)], spacing: 10) {
                ForEach(candidates) { c in
                    Button { setOverride(c.url) } label: {
                        ZStack {
                            if slot == .logo { RoundedRectangle(cornerRadius: 8).fill(c.source == "fanart" ? Color(white: 0.12) : Color.white) }
                            ArtworkImage(url: c.url, title: "artwork", aspect: slotAspect, cornerRadius: 8)
                                .overlay { if isCurrent(c.url) { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3) } }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal)
        }
    }

    private var slotAspect: CGFloat { switch slot { case .poster: 2 / 3; case .backdrop: 16 / 9; case .logo: 16 / 9 } }

    private var currentURL: URL? {
        switch target {
        case .collection(let c): return c.artworkURL.flatMap(URL.init)
        case .item(let i): switch slot { case .poster: return i.posterURL(size: .detail); case .backdrop: return i.backdropURL; case .logo: return i.titleLogoURL }
        }
    }
    private var hasOverride: Bool {
        switch target {
        case .collection(let c): return c.artworkURL != nil
        case .item(let i): switch slot { case .poster: return i.posterOverrideURL != nil; case .backdrop: return i.backdropOverrideURL != nil; case .logo: return i.logoOverrideURL != nil }
        }
    }
    private func isCurrent(_ url: URL) -> Bool { currentURL == url }

    private func setOverride(_ url: URL?) {
        switch target {
        case .collection(let c): library.setArtwork(url?.absoluteString, for: c)
        case .item(let i):
            let s: LibraryStore.ArtworkSlot = slot == .poster ? .poster : slot == .backdrop ? .backdrop : .logo
            library.setArtwork(url?.absoluteString, slot: s, for: i)
        }
    }

    private func load() async {
        guard case .item(let item) = target else { loading = false; return }
        guard let client = settings.tmdb, let id = item.tmdbID else { loading = false; error = "Add a TMDb API key in Settings."; return }
        do {
            let imgs = try await client.images(id: id, isShow: item.kind == .show)
            tmdb[.poster] = (imgs.posters ?? []).prefix(40).compactMap { ArtworkURL.poster($0.filePath, size: .detail) }.map { Candidate(url: $0, source: "tmdb") }
            tmdb[.backdrop] = (imgs.backdrops ?? []).prefix(40).compactMap { ArtworkURL.backdrop($0.filePath, size: .small) }.map { Candidate(url: $0, source: "tmdb") }
            tmdb[.logo] = (imgs.logos ?? []).prefix(40).compactMap { ArtworkURL.logo($0.filePath, size: .medium) }.map { Candidate(url: $0, source: "tmdb") }
        } catch { self.error = error.localizedDescription }
        if let fa = settings.fanart {
            let art: FanartArt?
            if item.kind == .show, let tvdb = item.tvdbID { art = try? await fa.show(tvdbID: tvdb) }
            else if item.kind == .film { art = try? await fa.movie(tmdbID: id) }
            else { art = nil }
            if let art {
                fanart[.poster] = art.posterURLs.compactMap(URL.init).map { Candidate(url: $0, source: "fanart") }
                fanart[.backdrop] = art.backgroundURLs.compactMap(URL.init).map { Candidate(url: $0, source: "fanart") }
                fanart[.logo] = art.logoURLs.compactMap(URL.init).map { Candidate(url: $0, source: "fanart") }
            }
        }
        loading = false
    }
}
