import SwiftUI

/// Chips row: fixed filters plus Genre and Year pickers that open sheets. Matches the prototype.
struct FilterBar: View {
    enum Quick: String, CaseIterable { case all = "All", unwatched = "Unwatched", favourites = "Favourites", uhd = "4K" }

    @Binding var quick: Quick
    @Binding var genre: String?
    @Binding var decade: String?
    var showUHD = false
    let genres: [String]
    let decades: [String]
    @State private var sheet: Sheet?
    private enum Sheet: Identifiable { case genre, year; var id: Int { hashValue } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Quick.allCases.filter { showUHD || $0 != .uhd }, id: \.self) { q in
                    Chip(text: q.rawValue, on: quick == q) { quick = q }
                }
                Chip(text: (genre ?? "Genre") + " ▾", on: genre != nil) { sheet = .genre }
                Chip(text: (decade ?? "Year") + " ▾", on: decade != nil) { sheet = .year }
            }
            .padding(.horizontal)
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                List {
                    switch which {
                    case .genre:
                        Row(title: "All genres", on: genre == nil) { genre = nil; sheet = nil }
                        ForEach(genres, id: \.self) { g in Row(title: g, on: genre == g) { genre = g; sheet = nil } }
                    case .year:
                        Row(title: "All years", on: decade == nil) { decade = nil; sheet = nil }
                        ForEach(decades, id: \.self) { d in Row(title: d, on: decade == d) { decade = d; sheet = nil } }
                    }
                }
                .navigationTitle(which == .genre ? "Genre" : "Year")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    struct Chip: View {
        let text: String; let on: Bool; let action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(text).font(.footnote.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(on ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                    .foregroundStyle(on ? .black : .primary)
            }.buttonStyle(.plain)
        }
    }

    struct Row: View {
        let title: String; let on: Bool; let action: () -> Void
        var body: some View {
            Button(action: action) {
                HStack { Text(title).foregroundStyle(.primary); Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }
            }
        }
    }

    static func decade(_ year: Int?) -> String? { year.map { "\($0 / 10 * 10)s" } }
}
