import SwiftUI
import MediaCore
import Metadata
import Playback

/// Search OpenSubtitles for the current item and download one into the player.
struct SubtitleSearchView: View {
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var engine: VLCPlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SubtitleResult] = []
    @State private var searching = false
    @State private var downloading: Int?
    @State private var error: String?
    @State private var language: String = "en"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(AppSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .onChange(of: language) { _, _ in Task { await search() } }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) } }
                Section {
                    if searching { HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) } }
                    else if results.isEmpty, error == nil { Text("No subtitles found.").foregroundStyle(.secondary) }
                    ForEach(results) { r in
                        Button { Task { await download(r) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.summary).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                                    Text("\(r.downloads) downloads").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if downloading == r.fileID { ProgressView() } else { Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
                            }
                        }.disabled(downloading != nil)
                    }
                } footer: {
                    Text(settings.openSubtitles?.canDownload == true ? "Subtitles from OpenSubtitles.com. The free account has a daily download limit." : "Searching works with the API key alone; downloading needs the OpenSubtitles username and password in Settings.")
                }
            }
            .navigationTitle("Find subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .onAppear { language = settings.subtitleLanguage; Task { await search() } }
    }

    private func search() async {
        guard let client = settings.openSubtitles else { error = OpenSubtitlesError.missingAPIKey.errorDescription; return }
        guard let item = player.current else { return }
        searching = true; error = nil
        do {
            if item.kind == .episode, let showID = item.show?.tmdbID {
                results = try await client.search(parentTMDbID: showID, season: item.seasonNumber, episode: item.episodeNumber, languages: [language])
            } else if item.kind == .film, let id = item.tmdbID {
                results = try await client.search(tmdbID: id, languages: [language])
            } else {
                results = try await client.search(query: item.title, languages: [language])
            }
            Diagnostics.log("subtitles", "search for \(item.title.prefix(40)) [\(language)]: \(results.count) results")
        } catch {
            self.error = error.localizedDescription
            Diagnostics.log("subtitles", "search failed: \(error.localizedDescription)")
        }
        searching = false
    }

    private func download(_ r: SubtitleResult) async {
        guard let client = settings.openSubtitles, let item = player.current else { return }
        downloading = r.fileID; error = nil
        do {
            let (data, name) = try await client.download(fileID: r.fileID)
            let url = try SubtitleStore.save(data, itemKey: item.itemKey, language: r.language, fileID: r.fileID, originalName: name)
            engine.addExternalSubtitle(url, select: true)
            player.rememberSubtitleChoice(language: r.language)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Diagnostics.log("subtitles", "download failed: \(error.localizedDescription)")
        }
        downloading = nil
    }
}
