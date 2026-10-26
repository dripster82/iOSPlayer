import SwiftUI
import AVKit
import MediaCore
import Library
import Playback

/// Apple's player, used when AirPlay is the active route: MP4, M4V and MOV directly (from a
/// download, an HTTP URL, or a share through the local bridge), and anything else through the HLS
/// copy VLC writes. Apple's player is the only path that sends the picture, not just the sound,
/// over AirPlay. Its own controls are hidden: they treat the growing copy as a live stream (no
/// times, a scrubber that cannot go past what has been copied), so Reel draws the controls it has
/// in its own player, in the file's own time, and restarts the copy when a seek lands outside the
/// part copied so far.
struct NativePlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerCoordinator
    @EnvironmentObject private var settings: AppSettings
    let playback: PlayerCoordinator.NativePlayback
    @State private var avPlayer: AVPlayer?
    @State private var endWatcher: Any?
    @State private var statusWatcher: NSKeyValueObservation?
    @State private var rateWatcher: NSKeyValueObservation?
    @State private var timeObserver: Any?
    @State private var heartbeat: Task<Void, Never>?
    @StateObject private var clock = PlaybackClock()
    @State private var scrubTime: TimeInterval?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var playing = false
    @State private var sought = false
    /// While set, a jump ahead in the first seconds (the receiver choosing a live copy's edge
    /// rather than its start) is undone; a seek of the viewer's own ends it.
    @State private var startGuardUntil: Date?
    @State private var audioOptions: [AVMediaSelectionOption] = []
    @State private var subtitleOptions: [AVMediaSelectionOption] = []
    @State private var selectedAudio: AVMediaSelectionOption?
    @State private var selectedSubtitle: AVMediaSelectionOption?
    @State private var rate: Float = 1
    @State private var fill = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayerController(player: avPlayer, fill: fill).ignoresSafeArea()
            // Taps on the picture show or hide the controls.
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture { controlsVisible ? hideControls() : showControls() }
            if controlsVisible { controls }
            if player.isLoading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    if let m = player.loadingMessage { Text(m).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { saveProgress(); tearDown() }
        .onChange(of: player.sleepFired) { _, _ in avPlayer?.pause(); saveProgress() }
        // Every 30 s during playback, as the device player does, so the other devices (and a crash)
        // see where this one got to.
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); if playing { saveProgress() } } }
    }

    // MARK: - Controls (the VLC player's layout, in the file's own time)

    private var controls: some View {
        VStack {
            HStack(spacing: 10) {
                circle("xmark") { close() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if !playback.subtitle.isEmpty { Text(playback.subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                        Label("AirPlay", systemImage: "airplayvideo").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                AirPlayButton().frame(width: 38, height: 38)
                Menu {
                    Button { select(nil, in: .legible) } label: { Label("Off", systemImage: selectedSubtitle == nil ? "checkmark" : "") }
                    ForEach(subtitleOptions, id: \.self) { o in
                        Button { select(o, in: .legible) } label: { Label(o.displayName, systemImage: o == selectedSubtitle ? "checkmark" : "") }
                    }
                    if subtitleOptions.isEmpty {
                        Divider()
                        Text("No subtitle tracks in this stream. Subtitle files next to the video travel with it; embedded ones do not yet.")
                    } else {
                        Divider()
                        delayMenu("Subtitle delay", current: playback.adjustments.subtitleDelay) { var a = playback.adjustments; a.subtitleDelay = $0; restart(with: a) }
                    }
                } label: { circleLabel("captions.bubble", on: selectedSubtitle != nil) }
                Menu {
                    ForEach(audioOptions, id: \.self) { o in
                        Button { select(o, in: .audible) } label: { Label(o.displayName, systemImage: o == selectedAudio ? "checkmark" : "") }
                    }
                    if audioOptions.isEmpty { Text("One audio track") }
                    Divider()
                    delayMenu("Audio delay", current: playback.adjustments.audioDelay) { var a = playback.adjustments; a.audioDelay = $0; restart(with: a) }
                    Toggle(isOn: Binding(get: { playback.adjustments.dialogueBoost }, set: { var a = playback.adjustments; a.dialogueBoost = $0; restart(with: a) })) { Label("Dialogue boost", systemImage: "waveform.badge.plus") }
                } label: { circleLabel("waveform", on: playback.adjustments.dialogueBoost) }
                Menu {
                    Menu {
                        Button { player.setSleepTimer(nil) } label: { Label("Off", systemImage: player.sleepTimer == nil ? "checkmark" : "") }
                        ForEach([15, 30, 45, 60], id: \.self) { m in
                            Button { player.setSleepTimer(.minutes(m)) } label: { Label("\(m) minutes", systemImage: player.sleepTimer == .minutes(m) ? "checkmark" : "") }
                        }
                        Button { player.setSleepTimer(.endOfEpisode) } label: { Label("End of episode", systemImage: player.sleepTimer == .endOfEpisode ? "checkmark" : "") }
                    } label: { Label("Sleep timer", systemImage: "moon.zzz") }
                } label: { circleLabel("ellipsis", on: player.sleepTimer != nil) }
            }
            Spacer()
            HStack(spacing: 44) {
                circle("gobackward.\(settings.skipInterval)", size: 54) { seek(to: fileTime - Double(settings.skipInterval)) }
                Button { togglePlayPause() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 32, weight: .bold)).foregroundStyle(.black).frame(width: 74, height: 74).background(Color.white, in: Circle())
                }
                circle("goforward.\(settings.skipInterval)", size: 54) { seek(to: fileTime + Double(settings.skipInterval)) }
            }
            Spacer()
            VStack(spacing: 6) {
                // The live preview opens the file in its own small player, so it works over AirPlay too.
                TimelineBar(clock: clock, chapters: playback.chapters, scrubTime: $scrubTime, itemKey: playback.itemKey, liveURL: player.previewURL(player.lastPlaybackURL), hardwareDecoding: player.previewHardwareDecoding) { seek(to: $0) }
                HStack(spacing: 8) {
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button { setRate(Float(r)) } label: { Label("\(r.formatted())×", systemImage: rate == Float(r) ? "checkmark" : "") }
                        }
                    } label: { Text("\(rate.formatted())×").font(.caption.bold()).foregroundStyle(rate != 1 ? .black : .white).padding(.horizontal, 10).padding(.vertical, 6).background(rate != 1 ? Color.accentColor : Color.white.opacity(0.15), in: Capsule()) }
                    if !playback.chapters.isEmpty {
                        circle("backward.frame", size: 30) { jumpChapter(-1) }
                        Menu {
                            ForEach(playback.chapters) { c in
                                Button { seek(to: c.start) } label: { Label(c.title, systemImage: isCurrent(c) ? "checkmark" : "bookmark") }
                            }
                        } label: { Text("Chapters").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6).background(Color.white.opacity(0.15), in: Capsule()) }
                        circle("forward.frame", size: 30) { jumpChapter(+1) }
                    }
                    Button { fill.toggle() } label: { Text(fill ? "Fill" : "Fit").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6).background(Color.white.opacity(0.15), in: Capsule()) }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false))
        .transition(.opacity)
    }

    /// Delays in steps; a change restarts the stream from here with the new value (a few seconds).
    private func delayMenu(_ title: String, current: TimeInterval, set: @escaping (TimeInterval) -> Void) -> some View {
        Menu {
            ForEach([-1.0, -0.5, -0.25, -0.1, 0, 0.1, 0.25, 0.5, 1.0], id: \.self) { d in
                Button { set(d) } label: { Label(d == 0 ? "None" : String(format: "%+.2f s", d), systemImage: abs(current - d) < 0.001 ? "checkmark" : "") }
            }
        } label: { Label(title + (current == 0 ? "" : String(format: " (%+.2f s)", current)), systemImage: "clock.arrow.2.circlepath") }
    }

    private func restart(with adjustments: HLSRemuxer.Adjustments) {
        guard adjustments != playback.adjustments else { return }
        saveProgress()
        player.restartNativeStream(at: fileTime, adjustments: adjustments)
    }

    private func circle(_ icon: String, size: CGFloat = 38, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(icon, size: size, on: on) }
    }
    private func circleLabel(_ icon: String, size: CGFloat = 38, on: Bool = false) -> some View {
        Image(systemName: icon).font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(on ? .black : .white)
            .frame(width: size, height: size).background(on ? Color.accentColor : Color.white.opacity(0.12), in: Circle())
    }

    private func showControls() { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }; scheduleHide() }
    private func hideControls() { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, playing, scrubTime == nil else { return }
            hideControls()
        }
    }

    // MARK: - Player

    private func start() {
        // SwiftUI can build this view more than once for one presentation; the player is made once.
        guard avPlayer == nil else { return }
        let item = AVPlayerItem(url: playback.url)
        // The title and episode show on the TV's now-playing display.
        item.externalMetadata = [metadata(.commonIdentifierTitle, playback.title), metadata(.iTunesMetadataTrackSubTitle, playback.subtitle)].compactMap { $0 }
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        p.play()
        avPlayer = p
        playing = true
        clock.set(time: playback.startAt + playback.timeOffset, duration: max(playback.knownDuration, 1))
        endWatcher = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            // The copy's end is the file's end only when the copy ran to the end: a kept whole copy,
            // or the live one (part-way copies included) having finished.
            let atEnd = playback.timeOffset == 0 || HLSRemuxer.completed(for: playback.itemKey) != nil || HLSRemuxer.shared.streamFinished
            Diagnostics.log("player", "native playback reached the copy's end\(atEnd ? ", the file's end" : "")")
            if atEnd { close(markWatched: true, continuing: true) } else { close() }
        }
        // Why a black screen, when it is one: the item's status and error go to the log. The start
        // position is applied once the item is ready; before that a seek is clamped to zero.
        statusWatcher = item.observe(\.status, options: [.new]) { item, _ in
            let message = item.error.map { " error: \(String(describing: $0))" } ?? ""
            Diagnostics.log("player", "native item status \(item.status.rawValue)\(message)")
            for ev in item.errorLog()?.events ?? [] { Diagnostics.log("player", "native error log \(ev.errorStatusCode) \(ev.errorComment ?? "") \(ev.uri ?? "")") }
            if item.status == .readyToPlay {
                Task { @MainActor in
                    // A live copy is a growing playlist, and the receiver may begin at its edge, tens of
                    // seconds past where the viewer was: ask for the start (or the resume point) outright.
                    if !sought, playback.startAt > 0 || playback.timeOffset > 0 {
                        sought = true
                        startGuardUntil = Date().addingTimeInterval(20)
                        p.seek(to: CMTime(seconds: playback.startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                    }
                    loadSelections(item)
                }
            }
        }
        rateWatcher = p.observe(\.timeControlStatus, options: [.new]) { p, _ in
            Task { @MainActor in playing = p.timeControlStatus != .paused; if playing { scheduleHide() } else { showControls() } }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
            guard t.seconds.isFinite else { return }
            let now = t.seconds + playback.timeOffset
            if let until = startGuardUntil {
                if Date() > until { startGuardUntil = nil }
                else if scrubTime == nil, t.seconds > playback.startAt + 15 {
                    startGuardUntil = nil
                    Diagnostics.log("player", "native playback began \(Int(t.seconds - playback.startAt))s past the start; seeking back")
                    p.seek(to: CMTime(seconds: playback.startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                    return
                }
            }
            player.nativeTime = now
            clock.set(time: now, duration: duration)
        }
        Diagnostics.log("player", "native AirPlay playback of \(Diagnostics.safe(playback.url)) from \(Int(playback.startAt + playback.timeOffset))s")
        heartbeat = Task { @MainActor in
            var ticks = 0, stuckFor = 0, lastTime = -1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let p = avPlayer else { return }
                ticks += 1
                let t = p.currentTime().seconds
                let waiting = p.reasonForWaitingToPlay.map { " waiting: \($0.rawValue)" } ?? ""
                let err = p.currentItem?.errorLog()?.events.last.map { " lastErr: \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? ""
                if ticks <= 24 {
                    Diagnostics.log("player", "native: external=\(p.isExternalPlaybackActive) control=\(p.timeControlStatus.rawValue) t=\(Int(t)) rate=\(p.rate) keepUp=\(p.currentItem?.isPlaybackLikelyToKeepUp ?? false)\(waiting)\(err)")
                }
                // A live copy that stops growing (the converter stalled, or Apple's player gave up on a
                // playlist that went stale) leaves the clock still while play is wanted: start the copy
                // again from here rather than sit on a black screen.
                let wantsPlay = p.timeControlStatus != .paused && scrubTime == nil
                let stuck = wantsPlay && (t == lastTime || p.reasonForWaitingToPlay == .noItemToPlay)
                stuckFor = stuck ? stuckFor + 1 : 0
                lastTime = t
                if stuckFor >= 3, playback.timeOffset > 0 || HLSRemuxer.completed(for: playback.itemKey) == nil {
                    Diagnostics.log("player", "native playback stuck at \(Int(fileTime))s for \(stuckFor * 5)s\(err); restarting the stream there")
                    stuckFor = 0
                    player.restartNativeStream(at: fileTime)
                    return
                }
            }
        }
        scheduleHide()
    }

    /// The file's length: what the library knows, else what the stream reports plus its offset.
    private var duration: TimeInterval {
        let streamed = (avPlayer?.currentItem?.duration.seconds ?? 0)
        let fromStream = streamed.isFinite && streamed > 0 ? streamed + playback.timeOffset : 0
        return max(playback.knownDuration, fromStream, 1)
    }

    private var fileTime: TimeInterval { clock.time }

    /// Where the copy can be seeked to right now, in file time.
    private var available: ClosedRange<TimeInterval> {
        let ranges = avPlayer?.currentItem?.seekableTimeRanges.map(\.timeRangeValue) ?? []
        let end = ranges.map { $0.end.seconds }.filter(\.isFinite).max() ?? 0
        return playback.timeOffset...(playback.timeOffset + end)
    }

    /// A seek inside the copied part is a seek; one beyond it restarts the copy there, which with
    /// VLC's copy or conversion takes a few seconds rather than waiting for the copy to catch up.
    private func seek(to fileTime: TimeInterval) {
        startGuardUntil = nil
        let target = max(0, min(duration, fileTime))
        if available.contains(target) || (playback.timeOffset == 0 && HLSRemuxer.completed(for: playback.itemKey) != nil) {
            avPlayer?.seek(to: CMTime(seconds: target - playback.timeOffset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
            clock.set(time: target, duration: duration)
        } else {
            Diagnostics.log("player", "native seek to \(Int(target))s is outside the copy (\(Int(available.lowerBound))–\(Int(available.upperBound))s); restarting the stream there")
            saveProgress(at: target)
            player.restartNativeStream(at: target)
        }
        showControls()
    }

    private func jumpChapter(_ step: Int) {
        let chapters = playback.chapters
        guard !chapters.isEmpty else { return }
        let now = fileTime
        let index = chapters.lastIndex { $0.start <= now + 1 } ?? 0
        let next = max(0, min(chapters.count - 1, index + step))
        seek(to: chapters[next].start)
    }

    private func isCurrent(_ c: Chapter) -> Bool { fileTime >= c.start && fileTime < c.start + c.duration }

    private func togglePlayPause() {
        guard let p = avPlayer else { return }
        if p.timeControlStatus == .paused { p.play(); p.rate = rate } else { p.pause() }
    }

    private func setRate(_ r: Float) {
        rate = r
        guard let p = avPlayer, p.timeControlStatus != .paused else { return }
        p.rate = r
    }

    private func loadSelections(_ item: AVPlayerItem) {
        let asset = item.asset
        Task {
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            await MainActor.run {
                audioOptions = audible?.options ?? []
                subtitleOptions = legible?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? []
                if let audible { selectedAudio = item.currentMediaSelection.selectedMediaOption(in: audible) }
                if let legible { selectedSubtitle = item.currentMediaSelection.selectedMediaOption(in: legible) }
            }
        }
    }

    private func select(_ option: AVMediaSelectionOption?, in characteristic: AVMediaCharacteristic) {
        guard let item = avPlayer?.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { return }
            await MainActor.run {
                item.select(option, in: group)
                if characteristic == .audible { selectedAudio = option } else { selectedSubtitle = option }
            }
        }
    }

    private func metadata(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
        guard !value.isEmpty else { return nil }
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    private func saveProgress(markWatched: Bool = false, at position: TimeInterval? = nil) {
        guard avPlayer != nil else { return }
        let pos = position ?? fileTime
        let total = duration
        guard total > 1 else { return }
        library.recordProgress(itemKey: playback.itemKey, position: markWatched ? total : pos, duration: total)
    }

    private func close(markWatched: Bool = false, continuing: Bool = false) {
        saveProgress(markWatched: markWatched)
        tearDown()
        player.endNativePlayback(atFileEnd: continuing, settings: settings)
    }

    private func tearDown() {
        hideTask?.cancel()
        if let o = timeObserver { avPlayer?.removeTimeObserver(o); timeObserver = nil }
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        if let w = endWatcher { NotificationCenter.default.removeObserver(w); endWatcher = nil }
        statusWatcher = nil
        rateWatcher = nil
        heartbeat?.cancel(); heartbeat = nil
        avPlayer = nil
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer?
    var fill = false
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.showsPlaybackControls = false   // Reel draws its own, in the file's time
        vc.allowsPictureInPicturePlayback = true
        vc.updatesNowPlayingInfoCenter = true
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if vc.videoGravity != gravity { vc.videoGravity = gravity }
    }
}
