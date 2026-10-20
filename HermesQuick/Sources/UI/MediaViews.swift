import SwiftUI

/// Images and files the agent referenced, shown under its reply.
struct MediaGallery: View {
    let refs: [MediaRef]

    var body: some View {
        let images = refs.filter(\.isImage)
        let files = refs.filter { !$0.isImage }
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(images) { ref in
                        RemoteImageTile(ref: ref, single: images.count == 1)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            if !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files) { FileChip(ref: $0) }
                }
            }
        }
    }
}

struct RemoteImageTile: View {
    let ref: MediaRef
    let single: Bool
    @State private var image: NSImage?
    @State private var failed: String?
    @State private var hovering = false

    var body: some View {
        let width: CGFloat = single ? 320 : 150
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: single ? .fit : .fill)
                    .frame(maxWidth: width, maxHeight: single ? 260 : 150)
                    .frame(width: single ? nil : width, height: single ? nil : 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if hovering {
                            HStack(spacing: 4) {
                                tileButton("square.and.arrow.down", "Save to Downloads") { save() }
                                tileButton("arrow.up.left.and.arrow.down.right", "Open in Preview") { open() }
                            }
                            .padding(6)
                            .transition(.opacity)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if let failed {
                Label(failed, systemImage: "photo.badge.exclamationmark")
                    .font(.app(11))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(width: width, height: 70)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .frame(width: width, height: single ? 200 : 150)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Open in Preview") { open() }
            Button("Save to Downloads") { save() }
            Button("Copy Image") {
                guard let image else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        .help(ref.name)
        .task(id: ref.key) {
            do {
                let img = try await MediaLoader.shared.image(for: ref)
                withAnimation(.smooth(duration: 0.3)) { image = img }
            } catch {
                failed = "Couldn't load \(ref.name)"
            }
        }
    }

    private func tileButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(11, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    private func open() { Task { try? await MediaLoader.shared.open(ref) } }

    private func save() {
        Task {
            if let url = try? await MediaLoader.shared.saveToDownloads(ref) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

struct FileChip: View {
    let ref: MediaRef
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Button {
            loading = true
            Task {
                do { try await MediaLoader.shared.open(ref); failed = false } catch { failed = true }
                loading = false
            }
        } label: {
            HStack(spacing: 6) {
                if loading { ProgressView().controlSize(.mini) }
                else { Image(systemName: failed ? "exclamationmark.triangle" : "doc.fill") }
                Text(ref.name).lineLimit(1)
            }
            .font(.app(12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contextMenu {
            Button("Save to Downloads") {
                Task {
                    if let url = try? await MediaLoader.shared.saveToDownloads(ref) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .help("Download and open \(ref.name)")
    }
}
