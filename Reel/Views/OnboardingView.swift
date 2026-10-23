import SwiftUI
import Library

/// First run: one screen, then straight into Add Source. The scan runs in the background with a banner on Home.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var adding = false
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "play.rectangle.fill").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Every file.\nEvery screen.").font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Plays MKV and almost everything else, straight from your NAS or this device. Sorted into TV and Films with artwork.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                SecureField("TMDb API key (optional, for artwork)", text: $key).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Free at themoviedb.org → Settings → API. You can add it later in Settings.").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                if !key.isEmpty { settings.tmdbAPIKey = key }
                adding = true
            } label: { Text("Get started").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Skip for now") { settings.hasCompletedOnboarding = true }.frame(maxWidth: .infinity).font(.footnote)
            Text("No account. Your files stay where they are.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(28)
        .background(RadialGradient(colors: [Color.accentColor.opacity(0.25), Color(.systemBackground)], center: .top, startRadius: 0, endRadius: 500).ignoresSafeArea())
        .sheet(isPresented: $adding, onDismiss: { settings.hasCompletedOnboarding = true }) {
            AddSourceView()
        }
    }
}
