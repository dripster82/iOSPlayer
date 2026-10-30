import Foundation
#if canImport(VLCKit)
import VLCKit
#endif

/// Reads a file's header through VLC without playing it: length, video codec and size, the audio
/// codecs and channel layouts, and how many subtitle tracks are embedded. A few seconds over the
/// share per file, nothing decoded. The same fields the player records when a file first plays,
/// so a film page can show them before anyone has watched it.
public enum MediaProbe {
    public struct Result: Sendable, Equatable {
        public var videoCodec: String?
        public var resolution: String?
        public var audio: String?
        public var subtitles: String?
        public var duration: TimeInterval
    }

    public static func probe(_ url: URL, timeoutMS: Int = 20000) async -> Result? {
        #if canImport(VLCKit)
        guard let media = VLCMedia(url: url) else { return nil }
        _ = media.parse(options: [.parseNetwork], timeout: Int32(timeoutMS))
        var waited = 0
        while media.parsedStatus != .done, media.parsedStatus != .failed, media.parsedStatus != .timeout, waited < timeoutMS / 100 + 5 {
            try? await Task.sleep(for: .milliseconds(100)); waited += 1
        }
        guard media.parsedStatus == .done else { return nil }
        let tracks = media.tracksInformation
        let video = tracks.first { $0.type == .video }
        let audio = tracks.filter { $0.type == .audio }.map { t -> String in
            [fourccName(t.fourcc != 0 ? t.fourcc : t.codec), t.audio.map { channelLabel(Int($0.channelsNumber)) }].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        let subs = tracks.filter { $0.type == .text }
        let subLanguages = Array(Set(subs.compactMap { $0.language })).sorted()
        let duration = TimeInterval(media.length.intValue) / 1000
        return Result(videoCodec: video.map { fourccName($0.fourcc != 0 ? $0.fourcc : $0.codec) },
                      resolution: video?.video.map { resolutionLabel(width: Int($0.width), height: Int($0.height)) },
                      audio: audio.isEmpty ? nil : Array(Set(audio)).sorted().joined(separator: " · "),
                      subtitles: subs.isEmpty ? nil : "\(subs.count) embedded" + (subLanguages.isEmpty ? "" : " (" + subLanguages.joined(separator: ", ") + ")"),
                      duration: duration)
        #else
        return nil
        #endif
    }

    static func channelLabel(_ n: Int) -> String { switch n { case 1: "mono"; case 2: "2.0"; case 6: "5.1"; case 8: "7.1"; default: "\(n)ch" } }

    static func resolutionLabel(width: Int, height: Int) -> String {
        if height >= 2000 || width >= 3800 { return "2160p" }
        if height >= 1000 || width >= 1900 { return "1080p" }
        if height >= 700 || width >= 1200 { return "720p" }
        return height > 0 ? "\(height)p" : "SD"
    }

    /// The common names for VLC's codec fourccs; anything else as its four letters.
    public static func fourccName(_ f: UInt32) -> String {
        let bytes = [UInt8(f & 0xff), UInt8((f >> 8) & 0xff), UInt8((f >> 16) & 0xff), UInt8((f >> 24) & 0xff)]
        let tag = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch tag {
        case "h264", "avc1", "x264": return "H.264"
        case "hevc", "hvc1", "hev1", "h265", "x265": return "HEVC"
        case "av01", "av1": return "AV1"
        case "vp90", "vp9": return "VP9"; case "vp80", "vp8": return "VP8"
        case "mp4v", "xvid", "divx", "dx50", "mpg4": return "MPEG-4"
        case "mpgv", "mp2v", "mpeg": return "MPEG-2"
        case "wmv3", "wvc1", "vc-1", "vc1": return "VC-1"
        case "mp4a", "aac", "aacl": return "AAC"
        case "ac-3", "a52", "ac3": return "AC-3"
        case "eac3", "ec-3", "e-ac3": return "E-AC-3"
        case "dts", "dts ", "dtsh", "dtsl": return "DTS"
        case "truehd", "trhd", "mlp": return "TrueHD"
        case "mpga", "mp3", "mp3 ", ".mp3": return "MP3"
        case "flac", "fla": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "vorb", "vorbis": return "Vorbis"
        case "pcm", "lpcm", "araw", "s16l", "s24l", "f32l": return "PCM"
        case "subt", "tx3g": return "Timed text"
        case "subp", "spu": return "VobSub"
        case "pgs", "hdmv": return "PGS"
        case "ssa", "ass": return "ASS"
        default: return tag.isEmpty ? "unknown" : tag.uppercased()
        }
    }
}
