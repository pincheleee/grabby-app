import SwiftUI

// MARK: - Preview Card

struct PreviewCard: View {
    let info: VideoInfo

    var body: some View {
        VStack(spacing: 0) {
            if let url = URL(string: info.thumbnail), !info.thumbnail.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(height: 180)
                .clipped()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    if !info.uploader.isEmpty { Text(info.uploader) }
                    if !info.durationString.isEmpty { Text(info.durationString) }
                    if !info.viewCountString.isEmpty { Text(info.viewCountString) }
                    if !info.filesizeString.isEmpty { Text("~\(info.filesizeString)") }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

// MARK: - Playlist View

struct PlaylistView: View {
    @Binding var entries: [PlaylistEntry]

    var selectedCount: Int { entries.filter(\.selected).count }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Playlist")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(selectedCount)/\(entries.count) selected")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All") { entries.indices.forEach { entries[$0].selected = true } }
                Button("None") { entries.indices.forEach { entries[$0].selected = false } }
            }
            .font(.system(size: 12, weight: .semibold))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { i in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $entries[i].selected)
                                .toggleStyle(.checkbox)

                            Text("\(i + 1)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            Text(entries[i].title)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)

                            Text(entries[i].durationString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        if i < entries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }
}

// MARK: - Progress Card

struct ProgressCard: View {
    @ObservedObject var job: DownloadJob
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(job.title.isEmpty ? "Downloading..." : job.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel download")
            }

            ProgressView(value: job.progress, total: 100)
                .tint(Color(hex: "ff5c39"))

            HStack {
                Text("\(job.progress, specifier: "%.1f")%")
                Spacer()
                Text(job.speed)
                Spacer()
                Text(job.eta.isEmpty ? "" : "ETA \(job.eta)")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

// MARK: - Queue Item Card

struct QueueItemCard: View {
    @ObservedObject var job: DownloadJob
    let onCancel: () -> Void
    let onReveal: () -> Void

    var statusColor: Color {
        switch job.status {
        case .done: return .green
        case .error, .cancelled: return .red
        case .downloading: return Color(hex: "ff5c39")
        case .queued: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(job.title.isEmpty ? job.id : job.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(job.status.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: job.progress, total: 100)
                .tint(job.status == .done ? .green : Color(hex: "ff5c39"))

            HStack {
                Text("\(job.progress, specifier: "%.1f")%")
                Spacer()
                if job.status == .downloading {
                    Text(job.speed)
                    Spacer()
                    Text(job.eta.isEmpty ? "" : "ETA \(job.eta)")
                } else if job.status == .done {
                    Button("Show in Finder", action: onReveal)
                        .font(.system(size: 11))
                } else if !job.error.isEmpty {
                    Text(job.error)
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)

            if job.status == .downloading || job.status == .queued {
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

// MARK: - History Item Row

struct HistoryItemRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 12) {
            if let url = URL(string: item.thumbnail), !item.thumbnail.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                }
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 80, height: 45)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(item.dateString)
                    Text(item.format.uppercased())
                    if !item.filesizeString.isEmpty { Text(item.filesizeString) }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}
