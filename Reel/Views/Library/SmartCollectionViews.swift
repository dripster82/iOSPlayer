import SwiftUI
import MediaCore
import Library

/// The grid of titles a smart collection matches right now.
struct SmartCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var smart: SmartCollectionStore
    let id: UUID
    @State private var items: [MediaItem] = []
    @State private var editing = false
    var body: some View {
        let rule = smart.all.first { $0.id == id }
        ScrollView {
            if let rule {
                Text(rule.summary).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 8)
                if items.isEmpty { ContentUnavailableView("Nothing matches yet", systemImage: "sparkles").padding(.top, 60) }
                else { ItemGrid(items: items, fixMatchTarget: .constant(nil)).padding(.vertical) }
            } else {
                ContentUnavailableView("Smart collection removed", systemImage: "sparkles")
            }
        }
        .navigationTitle(rule?.name ?? "Smart collection")
        .toolbar { if rule != nil { Button("Edit") { editing = true } } }
        .sheet(isPresented: $editing) { if let rule { SmartCollectionEditor(rule: rule) } }
        .refreshFromLibrary { items = rule?.matches(in: library) ?? [] }
        .onReceive(smart.$all) { all in items = all.first { $0.id == id }?.matches(in: library) ?? [] }
    }
}

/// Create or edit a rule.
struct SmartCollectionEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var smart: SmartCollectionStore
    @Environment(\.dismiss) private var dismiss
    @State var rule: SmartCollection
    var isNew = false

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $rule.name) }
                Section("Include") {
                    Picker("Type", selection: $rule.kind) { ForEach(SmartCollection.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Unwatched only", isOn: $rule.unwatchedOnly)
                    Toggle("Favourites only", isOn: $rule.favouritesOnly)
                }
                Section("Narrow down") {
                    optionalPicker("Genre", selection: $rule.genre, options: Array(Set(library.allGenres(kind: .film) + library.allGenres(kind: .show))).sorted())
                    optionalPicker("Universe", selection: $rule.universe, options: library.universes().map(\.name))
                    optionalPicker("Decade", selection: $rule.decade, options: ["2020s", "2010s", "2000s", "1990s", "1980s", "1970s", "1960s", "1950s"])
                    Picker("Runtime", selection: Binding(get: { rule.maxRuntimeMinutes ?? 0 }, set: { rule.maxRuntimeMinutes = $0 == 0 ? nil : $0 })) {
                        Text("Any").tag(0); Text("Under 90 min").tag(90); Text("Under 100 min").tag(100); Text("Under 2 hours").tag(120); Text("Under 3 hours").tag(180)
                    }
                    Picker("Rating", selection: Binding(get: { rule.minRating ?? 0 }, set: { rule.minRating = $0 == 0 ? nil : $0 })) {
                        Text("Any").tag(0.0); Text("6+").tag(6.0); Text("7+").tag(7.0); Text("8+").tag(8.0)
                    }
                    Picker("Added", selection: Binding(get: { rule.addedWithinDays ?? 0 }, set: { rule.addedWithinDays = $0 == 0 ? nil : $0 })) {
                        Text("Any time").tag(0); Text("This week").tag(7); Text("This month").tag(30); Text("Last 3 months").tag(90); Text("This year").tag(365)
                    }
                }
                Section {
                    Text("\(rule.matches(in: library).count) titles match now").font(.footnote).foregroundStyle(.secondary)
                }
                if !isNew {
                    Section { Button("Delete smart collection", role: .destructive) { smart.remove(rule.id); dismiss() } }
                }
            }
            .navigationTitle(isNew ? "New smart collection" : "Edit smart collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { smart.save(rule); dismiss() }.disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }

    private func optionalPicker(_ title: String, selection: Binding<String?>, options: [String]) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue ?? "" }, set: { selection.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text("Any").tag("")
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }
}
