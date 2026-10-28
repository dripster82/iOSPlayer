import SwiftUI
import Library
import Sync

/// First run: one screen, then straight into Add Source. The scan runs in the background with a banner on Home.
/// When this Apple ID already has a Reel library in iCloud (another device with sync on), restoring it
/// comes first: the sources, library and progress arrive by sync, so there is nothing to add by hand.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: SyncEngine
    @State private var adding = false
    @State private var key = ""
    @State private var cloud: CloudState = .checking
    @State private var restoring = false

    private enum CloudState { case checking, available, none }

    private func startAdding() {
        if !key.isEmpty { settings.tmdbAPIKey = key }
        adding = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "play.rectangle.fill").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Every file.\nEvery screen.").font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Plays MKV and almost everything else, straight from your NAS or this device. Sorted into TV and Films with artwork.").foregroundStyle(.secondary)
            if AppSettings.BuiltIn.tmdb.isEmpty {
                // Development builds without Secrets.xcconfig: the user supplies the key.
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("TMDb API key (optional, for artwork)", text: $key).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Free at themoviedb.org → Settings → API. You can add it later in Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if cloud == .available {
                Button {
                    if !key.isEmpty { settings.tmdbAPIKey = key }
                    restoring = true
                    Task {
                        await sync.enableAndFetch(cloudContainerID: AppSettings.cloudContainerID)
                        settings.hasCompletedOnboarding = true
                    }
                } label: {
                    HStack {
                        if restoring { ProgressView().tint(.white) }
                        Label(restoring ? "Restoring…" : "Restore from iCloud", systemImage: "icloud.and.arrow.down")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(restoring)
                Text("Your sources, library, progress and favourites from your other device. Share passwords come through iCloud Keychain.").font(.caption).foregroundStyle(.secondary)
            }
            if cloud == .available {
                Button { startAdding() } label: { Text("Add a source instead").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).disabled(restoring)
            } else {
                Button { startAdding() } label: { Text("Get started").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            Button {
                if !key.isEmpty { settings.tmdbAPIKey = key }
                DemoLibrary.install(in: library)
                settings.demoInstalled = true
                settings.hasCompletedOnboarding = true
            } label: { Label("Try with sample media", systemImage: "sparkles").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
            Button("Skip for now") { settings.hasCompletedOnboarding = true }.frame(maxWidth: .infinity).font(.footnote)
            Text("No account. Your files stay where they are.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(28)
        .background(RadialGradient(colors: [Color.accentColor.opacity(0.25), Color(.systemBackground)], center: .top, startRadius: 0, endRadius: 500).ignoresSafeArea())
        .sheet(isPresented: $adding, onDismiss: { settings.hasCompletedOnboarding = true }) {
            AddSourceView()
        }
        .task {
            // Quick and quiet: a device without iCloud, or with no Reel data there, sees the usual screen.
            cloud = await sync.cloudLibraryExists(cloudContainerID: AppSettings.cloudContainerID) ? .available : .none
        }
    }
}

