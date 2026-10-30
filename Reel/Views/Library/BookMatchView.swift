import SwiftUI
import MediaCore
import Library
import Metadata

/// Fix match for an audiobook: search Audible (and Apple Books) by title and author, pick the
/// edition, and the book takes its title, author, narrator, series, summary and cover.
struct BookMatchView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: MediaItem

    @State private var title = ""
    @State private var author = ""
    @State private var hits: [AudiobookHit] = []
    @State private var searching = false
    @State private var searched = false
    @State private var applying = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $title).textInputAutocapitalization(.words).onSubmit(search)
                    TextField("Author", text: $author).textInputAutocapitalization(.words).onSubmit(search)
                    Button(searching ? "Searching…" : "Search Audible", action: search).disabled(searching || title.isEmpty)
                } footer: {
                    Text("Audible's catalogue, with Apple Books when Audible has no such title. The chosen edition's details replace the book's; the files are not renamed.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    ForEach(hits) { hit in
                        Button { choose(hit) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                AsyncImage(url: hit.coverURL.flatMap(URL.init)) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hit.title + (hit.year.map { " (\($0))" } ?? "")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    if let a = hit.authorLine { Text(a).font(.caption).foregroundStyle(.secondary) }
                                    Text([hit.narratorLine.map { "Read by \($0)" }, hit.series.map { "\($0)\(hit.seriesPosition.map { ", book \($0)" } ?? "")" }, hit.runtimeMinutes.map { "\($0 / 60) h \($0 % 60) min" }, hit.source]
                                        .compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    if searched, !searching, hits.isEmpty { Text("Nothing found for “\(title)”. Try fewer words, or the author alone in the title box.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Fix Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if applying { ZStack { Color.black.opacity(0.2).ignoresSafeArea(); ProgressView("Applying…").padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } } }
            .interactiveDismissDisabled(applying)
            .onAppear {
                title = book.title
                author = book.author ?? ""
                search()
            }
        }
    }

    private func search() {
        guard !title.isEmpty else { return }
        searching = true; error = nil
        Task {
            hits = await AudiobookMetadata.lookup.search(title: title, author: author.isEmpty ? nil : author)
            searching = false; searched = true
        }
    }

    private func choose(_ hit: AudiobookHit) {
        guard !applying else { return }
        applying = true
        Task {
            defer { applying = false }
            let full = await AudiobookMetadata.lookup.details(hit)
            library.applyBookLookup(book, hit: full, manual: true)
            Diagnostics.log("library", "fix match (book): \(book.title.prefix(40)) → \(full.source) \(full.asin ?? "") \"\(full.title)\"")
            dismiss()
        }
    }
}
