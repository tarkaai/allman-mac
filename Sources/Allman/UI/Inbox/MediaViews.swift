// Inline rendering of downloaded attachments: images, files, voice notes, video.
// Files come from `allman media` (the CLI fetches with the session); the app
// only ever reads from disk here.

import AppKit
import AVKit
import SwiftUI

struct AttachmentView: View {
    let attachment: Attachment
    let fileURL: URL?
    let loading: Bool
    let onBlue: Bool

    var body: some View {
        switch attachment.type {
        case "image", "gif":
            if let fileURL { ImageAttachment(url: fileURL, attachment: attachment) } else { pending("Image") }
        case "video":
            if let fileURL { VideoAttachment(url: fileURL) } else { pending("Video") }
        case "audio", "voice":
            if let fileURL { AudioAttachment(url: fileURL, durationMs: attachment.durationMs, onBlue: onBlue) } else { pending("Voice message") }
        case "file":
            FileAttachment(attachment: attachment, fileURL: fileURL, loading: loading, onBlue: onBlue)
        default:
            AttachmentChip(attachment: attachment, onBlue: onBlue)
        }
    }

    private func pending(_ label: String) -> some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: attachment.symbolName) }
            Text(loading ? "\(label) · downloading…" : "\(label) · not available").font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(onBlue ? Color.white.opacity(0.15) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ImageAttachment: View {
    let url: URL
    let attachment: Attachment
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open in Preview")
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                    .frame(width: 200, height: 140)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            image = ImageCache.shared.local(url)
        }
    }
}

struct VideoAttachment: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(width: 320, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}

/// Voice-note style player: play/pause, scrubbing progress, duration.
struct AudioAttachment: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let durationMs: Int?
    let onBlue: Bool
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var progress: Double = 0
    @State private var observer: Any?

    var body: some View {
        let store = model.transcripts
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 140)
                    .tint(onBlue ? .white : .accentColor)
                Text(durationText).font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(onBlue ? Color.white.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
            // On-device transcript (Speech framework), cached per file.
            if let t = store.transcript(for: url) {
                Text(t).font(.callout).opacity(0.9).textSelection(.enabled).frame(maxWidth: 360, alignment: .leading)
            } else if store.inFlight.contains(TranscriptStore.key(for: url)) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Transcribing…").font(.caption).opacity(0.8) }
            } else if let err = store.failed[TranscriptStore.key(for: url)] {
                Text(err).font(.caption2).opacity(0.7)
            } else if !store.isEnabled {
                Button("Transcribe") { store.isEnabled = true; store.transcribe(url) }.buttonStyle(.link).font(.caption)
            }
        }
        .onAppear { store.transcribe(url) }
        .onDisappear { player?.pause(); playing = false }
    }

    private var durationText: String {
        let total = (durationMs ?? 0) / 1000
        return total > 0 ? String(format: "%d:%02d", total / 60, total % 60) : "voice"
    }

    private func toggle() {
        if player == nil {
            let p = AVPlayer(url: url)
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
                let d = p.currentItem?.duration.seconds ?? 0
                if d > 0 { progress = min(t.seconds / d, 1) }
                if d > 0, t.seconds >= d - 0.05 { playing = false; p.seek(to: .zero); progress = 0 }
            }
            player = p
        }
        if playing { player?.pause() } else { player?.play() }
        playing.toggle()
    }
}

struct FileAttachment: View {
    let attachment: Attachment
    let fileURL: URL?
    let loading: Bool
    let onBlue: Bool

    var body: some View {
        Button {
            if let fileURL { NSWorkspace.shared.open(fileURL) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name ?? "File").font(.callout.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption).opacity(0.8)
                }
                if fileURL == nil && loading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(onBlue ? Color.white.opacity(0.15) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fileURL == nil)
        .help(fileURL == nil ? "Downloading…" : "Open")
    }

    private var icon: String {
        switch (attachment.mimeType ?? "").lowercased() {
        case let m where m.contains("pdf"): return "doc.richtext"
        case let m where m.contains("zip"): return "doc.zipper"
        case let m where m.contains("word") || m.contains("document"): return "doc.text"
        case let m where m.contains("sheet") || m.contains("excel"): return "tablecells"
        case let m where m.contains("presentation") || m.contains("powerpoint"): return "rectangle.on.rectangle"
        default: return "doc"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let s = attachment.size, s > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)) }
        if let m = attachment.mimeType?.split(separator: "/").last { parts.append(String(m).uppercased()) }
        return parts.joined(separator: " · ")
    }
}
