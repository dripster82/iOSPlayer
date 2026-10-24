import SwiftUI
import Library

/// One switch, shared by every collection page: hide what has been watched. Films are watched when
/// ticked; shows when every episode is.
struct HideWatchedButton: View {
    @AppStorage("hideWatchedInCollections") private var hideWatched = false
    var body: some View {
        Button { hideWatched.toggle() } label: {
            Image(systemName: hideWatched ? "eye.slash.fill" : "eye")
        }
        .accessibilityLabel(hideWatched ? "Showing unwatched only" : "Hide watched")
    }
}

extension LibraryStore {
    /// `items` without the fully watched ones when the switch is on.
    func visible(_ items: [MediaItem], hideWatched: Bool) -> [MediaItem] {
        hideWatched ? items.filter { !isFullyWatched($0) } : items
    }
}
