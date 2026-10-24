import SwiftUI
import Library

/// Runs `action` when the view appears and again, debounced, after the library store changes, so a
/// screen can compute its rows into `@State` instead of querying the store inside `body` on every
/// render (the store publishes on every scan step and every sync).
struct LibraryRefresh: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    let action: () -> Void
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: action)
            .onReceive(library.objectWillChange) { _ in
                task?.cancel()
                task = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    action()
                }
            }
    }
}

extension View {
    func refreshFromLibrary(_ action: @escaping () -> Void) -> some View { modifier(LibraryRefresh(action: action)) }
}
