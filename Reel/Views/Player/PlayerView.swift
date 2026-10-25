import SwiftUI
import AVFoundation
import Combine
import MediaCore
import Library
import Playback
import Metadata

/// Full-screen player. Gestures: tap toggles controls, double-tap left/right skips, horizontal drag
/// scrubs, vertical drag on each half adjusts brightness/volume, long-press holds 2×, pinch toggles fill.
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerCoordinator
    var body: some View { PlayerContentView(engine: player.engine) }
}

struct PlayerContentView: View {
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var engine: VLCPlaybackEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var locked = false
    @State private var sheet: Sheet?
    @State private var scrubTime: TimeInterval?
    @State private var skipFlash: (left: Bool, id: UUID)?
    @State private var holdingSpeed = false
    @State private var fill = false
    @State private var volumeOverlay: Double?
    @State private var brightnessOverlay: Double?
    /// Level at the start of a vertical drag; the drag is applied as an offset from it, not accumulated.
    @State private var dragStartLevel: Double?
    @State private var copiedReport = false

    enum Sheet: Identifiable { case audio, subtitles, chapters, speed, more; var id: Int { hashValue } }


    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VLCVideoView(engine: engine).ignoresSafeArea()
                gestureLayer(size: geo.size)
                if engine.status == .opening || engine.status == .buffering || player.isLoading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        if player.isLoading, let m = player.loadingMessage { Text(m).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                    }
                }
                if let f = skipFlash { skipFlashView(left: f.left, size: geo.size).id(f.id) }
                if holdingSpeed { flag("2×") }
                if let v = volumeOverlay { verticalMeter(v, icon: "speaker.wave.2.fill").position(x: geo.size.width * 0.86, y: geo.size.height / 2) }
                if let b = brightnessOverlay { verticalMeter(b, icon: "sun.max.fill").position(x: geo.size.width * 0.14, y: geo.size.height / 2) }
                if locked { lockButton }
                // Position-dependent overlays live in their own view: observing the clock here would
                // redraw this body (and rebuild its gesture recognisers) every second.
                TimedOverlays(engine: engine, locked: locked)
                if controlsVisible && !locked { controls(size: geo.size) }
                if let err = player.loadError ?? failure { errorCard(err) }
                keyboardShortcuts
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { scheduleHide(); applyRememberedFill(player.preferredFill) }
        .onChange(of: player.preferredFill) { _, f in applyRememberedFill(f) }
        .onChange(of: controlsVisible) { _, visible in
            if !visible, let t = scrubTime { engine.seek(to: t); scrubTime = nil }
        }
        .onChange(of: scrubTime) { _, t in if t != nil { showControls() } }
        .onChange(of: engine.status) { _, s in
            if s == .playing { scheduleHide() } else { showControls() }
        }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // Like YouTube: leaving the app mid-playback hands the video to the system PiP window, and
            // coming back takes it over again. VLCKit may already have started PiP itself on the way out
            // (its controller allows automatic start from inline); `startPictureInPicture` is a no-op then.
            switch phase {
            case .background where engine.status == .playing: engine.startPictureInPicture()
            case .active: engine.stopPictureInPicture(); engine.verifyPlaybackAfterForeground()
            default: break
            }
        }
        .sheet(item: $sheet) { which in
            TrackSheet(kind: which, engine: engine, settings: settings, fill: $fill, onFill: { engine.setFill(fill) })
                .presentationDetents([.medium, .large]).presentationBackground(.thinMaterial)
                .onDisappear { scheduleHide() }
        }
    }

    private var failure: String? { if case .failed(let m) = engine.status { return m } else { return nil } }

    /// The fill the viewer chose last time for this show, when the player opens or the title changes.
    private func applyRememberedFill(_ remembered: Bool?) {
        let wanted = remembered ?? false
        if wanted != fill { fill = wanted; engine.setFill(fill) }
    }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        GestureLayer(
            onTap: {
                if locked { withAnimation { showLockHint() } } else { controlsVisible ? hideControls() : showControls() }
            },
            onDoubleTap: { location, layerSize in
                guard !locked else { return }
                let left = location.x < layerSize.width / 2
                engine.skip(by: left ? -Double(settings.skipInterval) : Double(settings.skipInterval))
                skipFlash = (left, UUID())
                controlsVisible ? hideControls() : showControls()   // undo the first tap's toggle
                Task { try? await Task.sleep(for: .milliseconds(600)); if skipFlash?.left == left { skipFlash = nil } }
            },
            onHoldBegan: { if !holdingSpeed, !locked { holdingSpeed = true; engine.setRate(2) } },
            onHoldEnded: { if holdingSpeed { holdingSpeed = false; engine.setRate(1) } },
            onDragChanged: { d in
                guard !locked, !holdingSpeed else { return }
                if abs(d.translation.width) > abs(d.translation.height) {
                    let delta = d.translation.width / d.size.width * min(engine.duration, 600)
                    scrubTime = max(0, min(engine.duration, engine.time + delta))
                } else {
                    // A full-height drag spans the whole range, measured from where the level was.
                    let frac = -d.translation.height / d.size.height
                    if d.start.x < d.size.width / 2 {
                        let start = dragStartLevel ?? ScreenBrightness.value
                        dragStartLevel = start
                        ScreenBrightness.value = start + frac
                        brightnessOverlay = ScreenBrightness.value
                    } else {
                        let start = dragStartLevel ?? Double(VolumeControl.current)
                        dragStartLevel = start
                        let level = max(0, min(1, start + frac))
                        volumeOverlay = level
                        VolumeControl.set(Float(level))
                    }
                }
            },
            onDragEnded: {
                if let t = scrubTime { engine.seek(to: t); scrubTime = nil }
                dragStartLevel = nil
                Task { try? await Task.sleep(for: .milliseconds(700)); volumeOverlay = nil; brightnessOverlay = nil }
            },
            onPinchEnded: { scale in guard !locked else { return }; fill = scale > 1; engine.setFill(fill); player.rememberFill(fill) }
        )
    }

    // MARK: - Controls

    private func controls(size: CGSize) -> some View {
        VStack {
            HStack(spacing: 10) {
                circle("xmark") { player.dismiss() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current.map { $0.kind == .episode ? ($0.show?.title ?? $0.title) : $0.title } ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.current.map { $0.kind == .episode ? [$0.episodeCode, $0.title].compactMap { $0 }.joined(separator: " · ") : ($0.year.map(String.init) ?? "") } ?? "").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                AirPlayButton().frame(width: 38, height: 38)
                if engine.canStartPictureInPicture { circle("pip.enter") { engine.startPictureInPicture() } }
                circle("captions.bubble", on: engine.currentSubtitleTrack != nil) { sheet = .subtitles }
                circle("waveform") { sheet = .audio }
                circle("ellipsis") { sheet = .more }
            }
            Spacer()
            HStack(spacing: 44) {
                circle("backward.end.fill", size: 54) { player.playPreviousOrRestart(settings: settings) }
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.status == .playing ? "pause.fill" : "play.fill").font(.system(size: 32, weight: .bold)).foregroundStyle(.black).frame(width: 74, height: 74).background(.white, in: Circle())
                }
                circle("forward.end.fill", size: 54) { player.playNext(settings: settings) }.opacity(player.upNext == nil ? 0.3 : 1)
            }
            Spacer()
            VStack(spacing: 6) {
                TimelineBar(clock: engine.clock, chapters: engine.chapters, scrubTime: $scrubTime, itemKey: player.current?.itemKey, liveURL: engine.currentURL, hardwareDecoding: settings.hardwareDecoding) { engine.seek(to: $0) }
                HStack(spacing: 8) {
                    tag("\(engine.rate.formatted())×", on: engine.rate != 1) { sheet = .speed }
                    if !engine.chapters.isEmpty {
                        circle("backward.frame", size: 30) { jumpChapter(-1) }
                        tag("Chapters") { sheet = .chapters }
                        circle("forward.frame", size: 30) { jumpChapter(+1) }
                    }
                    tag(fill ? "Fill" : "Fit") { fill.toggle(); engine.setFill(fill); player.rememberFill(fill) }
                    if player.sleepTimer != nil { tag("Sleep", on: true) { sheet = .more } }
                    Spacer()
                    circle("lock") { locked = true; controlsVisible = false }
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .foregroundStyle(.white)
        // The gradient is decoration: touches on empty areas must reach the gesture layer underneath so
        // tapping hides the controls and double-tap skip works while they are showing.
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false))
        .transition(.opacity)
    }

    private func circle(_ icon: String, size: CGFloat = 38, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: size, height: size).background(on ? Color.accentColor : Color.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel(Self.accessibilityLabel(for: icon, on: on))
    }

    /// VoiceOver names for the icon-only controls.
    private static func accessibilityLabel(for icon: String, on: Bool) -> String {
        switch icon {
        case "xmark": "Close"
        case "pip.enter": "Picture in Picture"
        case "captions.bubble": on ? "Subtitles, on" : "Subtitles"
        case "waveform": "Audio"
        case "ellipsis": "More"
        case "backward.end.fill": "Previous episode"
        case "forward.end.fill": "Next episode"
        case "backward.frame": "Previous chapter"
        case "forward.frame": "Next chapter"
        case "lock": "Lock controls"
        case "lock.open", "lock.fill": "Unlock controls"
        default: icon
        }
    }

    /// Hardware keyboard (iPad, Mac): space play/pause, arrows skip, S subtitles, A audio, F fill, Escape close.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { engine.togglePlayPause() }.keyboardShortcut(.space, modifiers: [])
            Button("") { engine.skip(by: -Double(settings.skipInterval)) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { engine.skip(by: Double(settings.skipInterval)) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { engine.skip(by: -60) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { engine.skip(by: 60) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { sheet = .subtitles }.keyboardShortcut("s", modifiers: [])
            Button("") { sheet = .audio }.keyboardShortcut("a", modifiers: [])
            Button("") { fill.toggle(); engine.setFill(fill); player.rememberFill(fill) }.keyboardShortcut("f", modifiers: [])
            Button("") { player.dismiss() }.keyboardShortcut(.escape, modifiers: [])
            Button("") { player.playNext(settings: settings) }.keyboardShortcut("n", modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    private func tag(_ text: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? Color.accentColor : .black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(on ? 0 : 0.3)))
                .foregroundStyle(on ? .black : .white)
        }
    }
    private func flag(_ text: String) -> some View {
        Text(text).font(.footnote.bold()).padding(.horizontal, 10).padding(.vertical, 4).background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 22)
    }
    private var lockButton: some View {
        Button { locked = false; showControls() } label: { Image(systemName: "lock.fill").foregroundStyle(.black).frame(width: 38, height: 38).background(Color.accentColor, in: Circle()) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 22)
    }
    private func skipFlashView(left: Bool, size: CGSize) -> some View {
        Text((left ? "−" : "+") + "\(settings.skipInterval)s").font(.headline.bold()).foregroundStyle(.white)
            .frame(width: size.width * 0.3, height: size.height)
            .background(Color.white.opacity(0.08), in: UnevenRoundedRectangle(topLeadingRadius: left ? 0 : 200, bottomLeadingRadius: left ? 0 : 200, bottomTrailingRadius: left ? 200 : 0, topTrailingRadius: left ? 200 : 0))
            .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
            .transition(.opacity)
    }
    private func verticalMeter(_ value: Double, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.white)
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(height: g.size.height * value)
                }
            }.frame(width: 6, height: 160)
        }
    }

    private func errorCard(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text("Can't play this").font(.headline)
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75))
                if engine.duration > 0 { Text("Your position at \(MediaFormat.clock(engine.time)) is saved.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                HStack {
                    if let item = player.current, player.loadError != nil || failure != nil {
                        Button("Retry") { player.retry(settings: settings) }.buttonStyle(.borderedProminent)
                        if let alt = item.files.first(where: { $0.id != player.currentFile?.id }) {
                            Button("Use \(alt.resolution ?? "other") copy") { player.loadError = nil; player.play(item, file: alt, settings: settings) }.buttonStyle(.bordered)
                        }
                    }
                    Button("Back") { player.dismiss() }.buttonStyle(.bordered)
                }
                HStack(spacing: 12) {
                    Button(copiedReport ? "Copied" : "Copy details") {
                        UIPasteboard.general.string = player.failureReport()
                        copiedReport = true
                        Task { try? await Task.sleep(for: .seconds(2)); copiedReport = false }
                    }.font(.footnote)
                    ShareLink(item: player.failureReport(), subject: Text("Reel playback report")) { Label("Share report", systemImage: "square.and.arrow.up").font(.footnote) }
                }.padding(.top, 4)
            }
            .padding(20).frame(maxWidth: 380).background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
        }
    }

    // MARK: - Helpers

    /// Previous = start of the current chapter, or the one before it when already near its start.
    private func jumpChapter(_ direction: Int) {
        let chapters = engine.chapters.sorted { $0.start < $1.start }
        guard !chapters.isEmpty else { return }
        let t = engine.time
        let currentIndex = chapters.lastIndex(where: { $0.start <= t + 0.5 }) ?? 0
        if direction > 0 {
            guard currentIndex + 1 < chapters.count else { return }
            engine.seek(to: chapters[currentIndex + 1].start)
        } else {
            let current = chapters[currentIndex]
            if t - current.start > 3 || currentIndex == 0 { engine.seek(to: current.start) } else { engine.seek(to: chapters[currentIndex - 1].start) }
        }
        showControls()
    }

    private func showControls() { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }; scheduleHide() }
    private func hideControls() { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            // A cancelled sleep throws, so `try?` alone would run on and hide the controls at once:
            // every showControls cancelled the previous timer, which then hid what had just been shown.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if engine.status == .playing, sheet == nil, scrubTime == nil { hideControls() }
        }
    }
    private func showLockHint() {}
}

/// Skip-intro button and Up Next card: the only overlays that depend on the position. They observe the
/// clock at 1 Hz so the main player body (and its gestures) never redraws for time.
struct TimedOverlays: View {
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var engine: VLCPlaybackEngine
    let locked: Bool
    @State private var now: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var upNextCountdown: Int?

    var body: some View {
        ZStack {
            if let intro = introWindow, now >= intro.start, now < intro.end, !locked {
                Button("Skip intro") { engine.seek(to: intro.end) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(28).padding(.bottom, 84)
            }
            if let next = player.upNext, duration > 0, duration - now < 20 || engine.status == .ended { upNextCard(next) }
        }
        .onChange(of: now) { _, t in
            if duration > 0, duration - t < 60, duration - t > 0, player.upNext != nil { player.prepareNext() }
        }
        .onReceive(engine.clock.$time.throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { t in
            let rounded = t.rounded()
            if rounded != now { now = rounded }
            if engine.clock.duration != duration { duration = engine.clock.duration }
        }
        .onChange(of: engine.status) { _, s in if s == .ended { startCountdown() } }
    }

    /// Chapters first (a named intro, or the unnamed-chapter shape rule); otherwise what the viewer's
    /// own skips have taught the app about this show.
    private var introWindow: IntroMemory.Window? {
        if let c = engine.chapters.intro { return IntroMemory.Window(start: c.start, end: c.start + c.duration) }
        return player.learnedIntro
    }

    private func upNextCard(_ next: MediaItem) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(url: ArtworkURL.still(next.stillPath) ?? ArtworkURL.poster(next.posterPath), title: next.title, aspect: 16 / 9, cornerRadius: 8).frame(width: 90, height: 90 * 9 / 16)
            VStack(alignment: .leading, spacing: 4) {
                Text("Up next" + (upNextCountdown.map { " · \($0)s" } ?? "")).font(.caption2.bold()).textCase(.uppercase).foregroundStyle(.white.opacity(0.6))
                Text("\(next.episodeCode ?? "") · \(next.title)").font(.footnote.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Button("Play now") { player.playNext(settings: settings) }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.small)
                    if upNextCountdown != nil {
                        Button("Cancel") { upNextCountdown = nil }.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button("Stop") { player.dismiss() }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(12).frame(width: 300).background(Color(white: 0.1, opacity: 0.95), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1)))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(28)
    }

    private func startCountdown() {
        guard player.upNext != nil, settings.autoPlayNext, !player.stopsAfterCurrent else { return }
        upNextCountdown = max(3, settings.autoPlayCountdown)
        Task {
            while let c = upNextCountdown, c > 0 { try? await Task.sleep(for: .seconds(1)); if upNextCountdown != nil { upNextCountdown = c - 1 } }
            if upNextCountdown == 0 { upNextCountdown = nil; player.playNext(settings: settings) }
        }
    }
}

/// The only part of the player that redraws on every clock tick.
struct TimelineBar: View {
    @ObservedObject var clock: PlaybackClock
    let chapters: [Chapter]
    @Binding var scrubTime: TimeInterval?
    var itemKey: String? = nil
    /// The stream a live preview can open alongside playback, and how to decode it.
    var liveURL: URL? = nil
    var hardwareDecoding = true
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let shown = scrubTime ?? clock.time
        Scrubber(time: shown, duration: clock.duration, chapters: chapters, preview: scrubTime, itemKey: itemKey, live: liveURL != nil) { scrubTime = $0 } onCommit: { onSeek($0); scrubTime = nil }
            .onChange(of: scrubTime) { was, now in
                guard let liveURL else { return }
                switch (was, now) {
                case (nil, let t?): ScrubPreview.shared.begin(url: liveURL, at: t, hardwareDecoding: hardwareDecoding)
                case (_?, let t?): ScrubPreview.shared.scrub(to: t)
                case (_?, nil): ScrubPreview.shared.end()
                default: break
                }
            }
        // The labels keep the live position and what is left; the bubble says where the finger is.
        HStack {
            Text(MediaFormat.clock(clock.time)).monospacedDigit()
            Spacer()
            Text("−" + MediaFormat.clock(clock.duration - clock.time)).monospacedDigit()
        }.font(.caption).foregroundStyle(.white.opacity(0.8))
    }
}

struct Scrubber: View {
    @ObservedObject private var thumbs = ScrubThumbnails.shared
    let time: TimeInterval
    let duration: TimeInterval
    let chapters: [Chapter]
    let preview: TimeInterval?
    var itemKey: String? = nil
    var live = false
    @ObservedObject private var livePreview = ScrubPreview.shared
    let onChange: (TimeInterval) -> Void
    let onCommit: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { g in
            let frac = duration > 0 ? CGFloat(time / duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: g.size.width * frac, height: 4)
                ForEach(chapters) { c in
                    Rectangle().fill(.black.opacity(0.6)).frame(width: 2, height: 4).offset(x: duration > 0 ? g.size.width * CGFloat(c.start / duration) : 0)
                }
                Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 2).offset(x: g.size.width * frac - 7)
                if let p = preview, duration > 0 {
                    let frame = itemKey.flatMap { thumbs.image(for: $0, fraction: p / duration) }
                    // The bubble lives inside the 28 pt scrubber row, so it must size itself: left to the
                    // row's proposal, the picture was squeezed to a one-pixel line and only the time showed.
                    VStack(spacing: 4) {
                        if live || frame != nil {
                            ZStack {
                                Color.black
                                // The strip's nearest frame at once; the live picture on top once it has one.
                                if let frame { Image(uiImage: frame).resizable().scaledToFill() }
                                if live { LivePreviewView().opacity(livePreview.hasPicture ? 1 : 0) }
                            }
                            .frame(width: 176, height: 99)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.8), lineWidth: 1)).shadow(radius: 4)
                        }
                        Text(MediaFormat.clock(p)).font(.caption.bold()).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.black)
                    }
                    .fixedSize()
                    .offset(x: max(0, min(g.size.width - (frame == nil && !live ? 60 : 176), g.size.width * CGFloat(p / duration) - (frame == nil && !live ? 30 : 88))), y: frame == nil && !live ? -30 : -82)
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in onChange(max(0, min(duration, Double(v.location.x / g.size.width) * duration))) }
                .onEnded { v in onCommit(max(0, min(duration, Double(v.location.x / g.size.width) * duration))) })
        }.frame(height: 28)
    }
}

/// The view the scrub preview player paints into. Exists only while the bubble is up.
struct LivePreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        ScrubPreview.shared.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        Task { @MainActor in if ScrubPreview.shared.drawable === uiView { ScrubPreview.shared.drawable = nil } }
    }
}

struct TrackSheet: View {
    let kind: PlayerContentView.Sheet
    @ObservedObject var engine: VLCPlaybackEngine
    let settings: AppSettings
    @Binding var fill: Bool
    let onFill: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerCoordinator
    @State private var searchingSubtitles = false

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .audio:
                    ForEach(engine.audioTracks) { t in row(t.name, sub: t.language, on: engine.currentAudioTrack == t.id) { engine.selectAudioTrack(t.id); player.rememberAudioChoice(language: t.language) } }
                    delayRow("Audio delay", value: engine.audioDelay) { engine.setAudioDelay($0) }
                case .subtitles:
                    row("Off", sub: nil, on: engine.currentSubtitleTrack == nil) { engine.selectSubtitleTrack(nil); player.rememberSubtitleChoice(language: "off") }
                    ForEach(engine.subtitleTracks) { t in row(t.name, sub: t.isForced ? "Forced" : "Embedded", on: engine.currentSubtitleTrack == t.id) { engine.selectSubtitleTrack(t.id); player.rememberSubtitleChoice(language: t.language ?? "on") } }
                    Section {
                        Button { searchingSubtitles = true } label: { Label("Find subtitles online…", systemImage: "magnifyingglass") }
                            .disabled(settings.openSubtitles == nil)
                        if settings.openSubtitles == nil { Text("Add an OpenSubtitles API key in Settings → Subtitles.").font(.footnote).foregroundStyle(.secondary) }
                    }
                    delayRow("Subtitle delay", value: engine.subtitleDelay) { engine.setSubtitleDelay($0) }
                case .chapters:
                    ForEach(engine.chapters) { c in row(c.title, sub: MediaFormat.clock(c.start), on: engine.time >= c.start && engine.time < c.start + c.duration) { engine.seek(to: c.start); dismiss() } }
                case .speed:
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in row("\(r.formatted())×", sub: r == 1 ? "Normal" : nil, on: engine.rate == Float(r)) { engine.setRate(Float(r)); player.rememberRate(Float(r)); dismiss() } }
                    Text("Remembered for this show.").font(.footnote).foregroundStyle(.secondary)
                case .more:
                    Toggle("Fill screen", isOn: $fill).onChange(of: fill) { _, f in onFill(); player.rememberFill(f) }
                    Toggle(isOn: Binding(get: { settings.dialogueBoost }, set: { settings.dialogueBoost = $0; player.reapplyOptions(settings: settings) })) {
                        VStack(alignment: .leading) { Text("Dialogue boost"); Text("Lifts quiet speech, tames loud scenes. Reloads the stream at this position.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Picker(selection: Binding(get: { player.sleepTimer }, set: { player.setSleepTimer($0) })) {
                        Text("Off").tag(PlayerCoordinator.SleepTimer?.none)
                        ForEach([15, 30, 45, 60, 90], id: \.self) { m in Text("\(m) minutes").tag(PlayerCoordinator.SleepTimer?.some(.minutes(m))) }
                        Text("End of this episode").tag(PlayerCoordinator.SleepTimer?.some(.endOfEpisode))
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Sleep timer")
                            if let at = player.sleepFiresAt { Text("Pauses \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                            else if player.sleepTimer == .endOfEpisode { Text("Stops when this episode ends; no auto-play.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Button { engine.startPictureInPicture(); dismiss() } label: { Label("Picture in Picture", systemImage: "pip.enter") }
                        .disabled(!engine.canStartPictureInPicture)
                    Label("With an AirPlay speaker or TV selected before you press Play, MP4/MOV files over HTTP or from Downloads stream natively; MKV and SMB mirror the screen.", systemImage: "airplayvideo").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $searchingSubtitles) { SubtitleSearchView(engine: engine) }
        }
    }

    private var title: String { switch kind { case .audio: "Audio"; case .subtitles: "Subtitles"; case .chapters: "Chapters"; case .speed: "Speed"; case .more: "More" } }

    private func row(_ title: String, sub: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) { Text(title).foregroundStyle(.primary); if let sub { Text(sub).font(.caption).foregroundStyle(.secondary) } }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }
    private func delayRow(_ title: String, value: TimeInterval, set: @escaping (TimeInterval) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { set(value - 0.1) } label: { Image(systemName: "minus") }.buttonStyle(.bordered)
            Text(String(format: "%+.1f s", value)).monospacedDigit().frame(width: 64)
            Button { set(value + 0.1) } label: { Image(systemName: "plus") }.buttonStyle(.bordered)
        }
    }
}

import AVKit
import MediaPlayer

/// System AirPlay route picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Color.accentColor)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// System volume via the hidden MPVolumeView slider (the only supported way to set volume programmatically).
enum VolumeControl {
    private static let view = MPVolumeView(frame: .zero)
    /// The current system volume.
    static var current: Float { AVAudioSession.sharedInstance().outputVolume }
    static func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.async { slider.value = value }
    }
}
