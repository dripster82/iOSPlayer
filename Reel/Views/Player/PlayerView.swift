import SwiftUI
import Combine
import MediaCore
import Library
import Playback

/// Full-screen player. Gestures: tap toggles controls, double-tap left/right skips, horizontal drag
/// scrubs, vertical drag on each half adjusts brightness/volume, long-press holds 2×, pinch toggles fill.
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerCoordinator
    var body: some View { PlayerContentView(engine: player.engine) }
}

struct PlayerContentView: View {
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var engine: VLCPlaybackEngine

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var locked = false
    @State private var sheet: Sheet?
    @State private var scrubTime: TimeInterval?
    @State private var skipFlash: (left: Bool, id: UUID)?
    @State private var holdingSpeed = false
    @State private var fill = false
    @State private var upNextCountdown: Int?
    @State private var volumeOverlay: Double?
    @State private var brightnessOverlay: Double?
    /// Coarse copy of the clock (1 Hz) for the few conditions that depend on position, so the whole
    /// view is not rebuilt on every VLC tick. The scrubber observes the clock itself.
    @State private var coarseTime: TimeInterval = 0
    @State private var coarseDuration: TimeInterval = 0

    enum Sheet: Identifiable { case audio, subtitles, chapters, speed, more; var id: Int { hashValue } }


    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VLCVideoView(engine: engine).ignoresSafeArea()
                gestureLayer(size: geo.size)
                if engine.status == .opening || engine.status == .buffering || player.isLoading { ProgressView().controlSize(.large).tint(.white) }
                if let f = skipFlash { skipFlashView(left: f.left, size: geo.size).id(f.id) }
                if holdingSpeed { flag("2×") }
                if let v = volumeOverlay { verticalMeter(v, icon: "speaker.wave.2.fill").position(x: geo.size.width * 0.86, y: geo.size.height / 2) }
                if let b = brightnessOverlay { verticalMeter(b, icon: "sun.max.fill").position(x: geo.size.width * 0.14, y: geo.size.height / 2) }
                if locked { lockButton }
                if let intro = engine.chapters.first(where: \.looksLikeIntro), coarseTime >= intro.start, coarseTime < intro.start + intro.duration, !locked {
                    Button("Skip intro") { engine.seek(to: intro.start + intro.duration) }
                        .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(28).padding(.bottom, 84)
                }
                if controlsVisible && !locked { controls(size: geo.size) }
                if let next = player.upNext, coarseDuration > 0, coarseDuration - coarseTime < 20 || engine.status == .ended { upNextCard(next) }
                if let err = player.loadError ?? failure { errorCard(err) }
            }
        }
        .onReceive(engine.clock.$time.throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { t in
            let rounded = t.rounded()
            if rounded != coarseTime { coarseTime = rounded }
            if engine.clock.duration != coarseDuration { coarseDuration = engine.clock.duration }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { scheduleHide() }
        .onChange(of: engine.status) { _, s in
            if s == .ended { startCountdown() }
            if s == .playing { scheduleHide() } else { showControls() }
        }
        .onDisappear { hideTask?.cancel() }
        .sheet(item: $sheet) { which in
            TrackSheet(kind: which, engine: engine, settings: settings, fill: $fill, onFill: { engine.setFill(fill) })
                .presentationDetents([.medium, .large]).presentationBackground(.thinMaterial)
                .onDisappear { scheduleHide() }
        }
    }

    private var failure: String? { if case .failed(let m) = engine.status { return m } else { return nil } }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    guard !locked else { return }
                    let left = v.location.x < size.width / 2
                    engine.skip(by: left ? -Double(settings.skipInterval) : Double(settings.skipInterval))
                    skipFlash = (left, UUID())
                    Task { try? await Task.sleep(for: .milliseconds(600)); if skipFlash?.left == left { skipFlash = nil } }
                }
                .exclusively(before: TapGesture().onEnded {
                    if locked { withAnimation { showLockHint() } } else { controlsVisible ? hideControls() : showControls() }
                })
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).sequenced(before: DragGesture(minimumDistance: 0)).onChanged { v in
                    if case .second = v, !holdingSpeed, !locked { holdingSpeed = true; engine.setRate(2) }
                }.onEnded { _ in if holdingSpeed { holdingSpeed = false; engine.setRate(1) } }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { v in
                    guard !locked, !holdingSpeed else { return }
                    if abs(v.translation.width) > abs(v.translation.height) {
                        let delta = v.translation.width / size.width * min(engine.duration, 600)
                        scrubTime = max(0, min(engine.duration, engine.time + delta))
                        showControls()
                    } else {
                        let frac = -v.translation.height / size.height
                        if v.startLocation.x < size.width / 2 {
                            UIScreen.main.brightness = max(0, min(1, UIScreen.main.brightness + frac * 0.04))
                            brightnessOverlay = UIScreen.main.brightness
                        } else {
                            volumeOverlay = max(0, min(1, (volumeOverlay ?? 0.5) + frac * 0.04))
                            VolumeControl.set(Float(volumeOverlay!))
                        }
                    }
                }.onEnded { _ in
                    if let t = scrubTime { engine.seek(to: t); scrubTime = nil }
                    Task { try? await Task.sleep(for: .milliseconds(700)); volumeOverlay = nil; brightnessOverlay = nil }
                }
            )
            .simultaneousGesture(MagnificationGesture().onEnded { s in guard !locked else { return }; fill = s > 1; engine.setFill(fill) })
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
                circle("captions.bubble", on: engine.currentSubtitleTrack != nil) { sheet = .subtitles }
                circle("waveform") { sheet = .audio }
                circle("ellipsis") { sheet = .more }
            }
            Spacer()
            HStack(spacing: 44) {
                circle("backward.end.fill", size: 54) { engine.seek(to: 0) }
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.status == .playing ? "pause.fill" : "play.fill").font(.system(size: 32, weight: .bold)).foregroundStyle(.black).frame(width: 74, height: 74).background(.white, in: Circle())
                }
                circle("forward.end.fill", size: 54) { player.playNext(settings: settings) }.opacity(player.upNext == nil ? 0.3 : 1)
            }
            Spacer()
            VStack(spacing: 6) {
                TimelineBar(clock: engine.clock, chapters: engine.chapters, scrubTime: $scrubTime) { engine.seek(to: $0) }
                HStack(spacing: 8) {
                    tag("\(engine.rate.formatted())×", on: engine.rate != 1) { sheet = .speed }
                    if !engine.chapters.isEmpty { tag("Chapters") { sheet = .chapters } }
                    tag(fill ? "Fill" : "Fit") { fill.toggle(); engine.setFill(fill) }
                    Spacer()
                    circle("lock") { locked = true; controlsVisible = false }
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .transition(.opacity)
    }

    private func circle(_ icon: String, size: CGFloat = 38, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: size, height: size).background(on ? Color.accentColor : Color.white.opacity(0.12), in: Circle())
        }
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

    private func upNextCard(_ next: MediaItem) -> some View {
        HStack(spacing: 10) {
            ArtworkImage(url: nil, title: next.title, aspect: 16 / 9, cornerRadius: 8).frame(width: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text("Up next" + (upNextCountdown.map { " · \($0)s" } ?? "")).font(.caption2.bold()).textCase(.uppercase).foregroundStyle(.white.opacity(0.6))
                Text("\(next.episodeCode ?? "") · \(next.title)").font(.footnote.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Button("Play now") { player.playNext(settings: settings) }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.small)
                    Button("Stop") { upNextCountdown = nil; player.dismiss() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(12).frame(width: 300).background(Color(white: 0.1, opacity: 0.95), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.1)))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(28)
    }

    private func errorCard(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text("Can't play this").font(.headline)
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75))
                if coarseDuration > 0 { Text("Your position at \(MediaFormat.clock(coarseTime)) is saved.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                HStack {
                    if let item = player.current, player.loadError != nil || failure != nil {
                        Button("Retry") { player.loadError = nil; player.play(item, file: player.currentFile, settings: settings) }.buttonStyle(.borderedProminent)
                        if let alt = item.files.first(where: { $0.id != player.currentFile?.id }) {
                            Button("Use \(alt.resolution ?? "other") copy") { player.loadError = nil; player.play(item, file: alt, settings: settings) }.buttonStyle(.bordered)
                        }
                    }
                    Button("Back") { player.dismiss() }.buttonStyle(.bordered)
                }
            }
            .padding(20).frame(maxWidth: 380).background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
        }
    }

    // MARK: - Helpers

    private func showControls() { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }; scheduleHide() }
    private func hideControls() { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(for: .seconds(3)); if engine.status == .playing, sheet == nil { hideControls() } }
    }
    private func showLockHint() {}
    private func startCountdown() {
        guard player.upNext != nil, settings.autoPlayNext else { return }
        upNextCountdown = 15
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
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let shown = scrubTime ?? clock.time
        Scrubber(time: shown, duration: clock.duration, chapters: chapters, preview: scrubTime) { scrubTime = $0 } onCommit: { onSeek($0); scrubTime = nil }
        HStack {
            Text(MediaFormat.clock(shown)).monospacedDigit()
            Spacer()
            Text("−" + MediaFormat.clock(clock.duration - shown)).monospacedDigit()
        }.font(.caption).foregroundStyle(.white.opacity(0.8))
    }
}

struct Scrubber: View {
    let time: TimeInterval
    let duration: TimeInterval
    let chapters: [Chapter]
    let preview: TimeInterval?
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
                    Text(MediaFormat.clock(p)).font(.caption.bold()).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.black)
                        .offset(x: max(0, min(g.size.width - 60, g.size.width * CGFloat(p / duration) - 30)), y: -30)
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

struct TrackSheet: View {
    let kind: PlayerContentView.Sheet
    @ObservedObject var engine: VLCPlaybackEngine
    let settings: AppSettings
    @Binding var fill: Bool
    let onFill: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .audio:
                    ForEach(engine.audioTracks) { t in row(t.name, sub: t.language, on: engine.currentAudioTrack == t.id) { engine.selectAudioTrack(t.id) } }
                    delayRow("Audio delay", value: engine.audioDelay) { engine.setAudioDelay($0) }
                case .subtitles:
                    row("Off", sub: nil, on: engine.currentSubtitleTrack == nil) { engine.selectSubtitleTrack(nil) }
                    ForEach(engine.subtitleTracks) { t in row(t.name, sub: t.isForced ? "Forced" : "Embedded", on: engine.currentSubtitleTrack == t.id) { engine.selectSubtitleTrack(t.id) } }
                    Section { Label("Search online (OpenSubtitles) — coming in phase 3", systemImage: "magnifyingglass").foregroundStyle(.secondary).font(.footnote) }
                    delayRow("Subtitle delay", value: engine.subtitleDelay) { engine.setSubtitleDelay($0) }
                case .chapters:
                    ForEach(engine.chapters) { c in row(c.title, sub: MediaFormat.clock(c.start), on: engine.time >= c.start && engine.time < c.start + c.duration) { engine.seek(to: c.start); dismiss() } }
                case .speed:
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in row("\(r.formatted())×", sub: r == 1 ? "Normal" : nil, on: engine.rate == Float(r)) { engine.setRate(Float(r)); dismiss() } }
                case .more:
                    Toggle("Fill screen", isOn: $fill).onChange(of: fill) { _, _ in onFill() }
                    Label("Picture in Picture — phase 4", systemImage: "pip").foregroundStyle(.secondary)
                    Label("AirPlay video is screen mirroring with VLCKit; audio-only AirPlay streams natively.", systemImage: "airplayvideo").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
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
    static func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.async { slider.value = value }
    }
}
