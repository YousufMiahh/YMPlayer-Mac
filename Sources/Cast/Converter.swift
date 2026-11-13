import Foundation

/// Turns any film or episode into a stream an Apple TV or Chromecast can play: HLS with H.264
/// video and AAC audio, written into a temporary folder that LocalServer hands to the TV.
/// Uses FFmpeg (bundled inside the app). Video that's already H.264 is copied as it is; anything
/// else is converted with the Mac's video chip.
final class Converter {
    let folder: URL
    let startAt: Double
    private var process: Process?

    static var ffmpeg: URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg"), FileManager.default.isExecutableFile(atPath: u.path) { return u }
        return nil
    }

    static var available: Bool { ffmpeg != nil }

    init(startAt: Double) {
        self.startAt = max(0, startAt)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ymcast-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { stop() }

    /// Which video codec the stream uses ("h264", "hevc", …), found by asking FFmpeg to read its header.
    static func videoCodec(_ url: URL, userAgent: String) -> String? {
        guard let ff = ffmpeg else { return nil }
        let p = Process()
        p.executableURL = ff
        p.arguments = ["-hide_banner", "-user_agent", userAgent, "-probesize", "5000000", "-analyzeduration", "5000000", "-i", url.absoluteString]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "Video: ([a-z0-9_]+)", options: .regularExpression) else { return nil }
        return String(text[r]).replacingOccurrences(of: "Video: ", with: "")
    }

    private static var encoderList: String?

    /// Hardware H.264 if this FFmpeg has it, else the software encoder.
    static func videoEncoderArgs() -> [String] {
        if encoderList == nil, let ff = ffmpeg {
            let p = Process()
            p.executableURL = ff
            p.arguments = ["-hide_banner", "-encoders"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                encoderList = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
            }
        }
        let scale = ["-vf", "scale='min(1920,iw)':-2", "-pix_fmt", "yuv420p"]
        if encoderList?.contains("h264_videotoolbox") == true {
            return ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-maxrate", "10M", "-bufsize", "16M", "-profile:v", "high"] + scale
        }
        return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-maxrate", "10M", "-bufsize", "16M"] + scale
    }

    /// Starts converting from `startAt` seconds. Background thread (it probes the stream first).
    func start(input: URL, userAgent: String, live: Bool) -> Bool {
        guard let ff = Converter.ffmpeg else { return false }
        let codec = Converter.videoCodec(input, userAgent: userAgent)
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-user_agent", userAgent,
                    "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        if startAt > 1 && !live { args += ["-ss", String(Int(startAt))] }
        args += ["-i", input.absoluteString, "-map", "0:v:0", "-map", "0:a:0?"]
        args += codec == "h264" ? ["-c:v", "copy"] : Converter.videoEncoderArgs()
        args += ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        args += ["-f", "hls", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "event",
                 "-hls_flags", "independent_segments",
                 "-hls_segment_filename", folder.appendingPathComponent("seg%05d.ts").path,
                 folder.appendingPathComponent("index.m3u8").path]
        let p = Process()
        p.executableURL = ff
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        process = p
        return true
    }

    /// The playlist exists and has at least one piece (so the TV won't give up straight away).
    var isReady: Bool {
        guard let s = try? String(contentsOf: folder.appendingPathComponent("index.m3u8"), encoding: .utf8) else { return false }
        return s.contains(".ts")
    }

    var isRunning: Bool { process?.isRunning == true }

    /// How many seconds are converted so far (from the playlist).
    var convertedSeconds: Double {
        guard let s = try? String(contentsOf: folder.appendingPathComponent("index.m3u8"), encoding: .utf8) else { return 0 }
        var total = 0.0
        for line in s.split(separator: "\n") where line.hasPrefix("#EXTINF:") {
            total += Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
        }
        return total
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        LocalServer.shared.unpublish(folder)
        try? FileManager.default.removeItem(at: folder)
    }
}
