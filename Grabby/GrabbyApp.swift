import SwiftUI

@main
struct GrabbyApp: App {
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var historyStore = HistoryStore.shared
    @StateObject private var prefsStore = PreferencesStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(historyStore)
                .environmentObject(prefsStore)
                .frame(minWidth: 520, minHeight: 640)
                .onDrop(of: [.url, .text], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 700, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Check for yt-dlp Updates") {
                    Task { await YTDLPService.shared.updateYTDLP() }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(prefsStore)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            downloadManager.pendingURL = url.absoluteString
                        }
                    }
                }
                return true
            }
            provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
                if let text = item as? String, text.contains("youtube.com") || text.contains("youtu.be") {
                    DispatchQueue.main.async {
                        downloadManager.pendingURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return true
    }
}
