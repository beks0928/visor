import AppKit
import SwiftUI

/// Сервис, который Visor умеет показывать в плеере. Кнопка открывает приложение, а если его нет на Mac, то сайт.
struct MusicApp: Identifiable {
    let id: String
    let name: String
    let bundleIDs: [String]
    /// Имена файлов в «Программах», если у приложения неизвестный идентификатор.
    let fileNames: [String]
    let site: URL
    let tint: UInt32
    /// Идентификаторы MediaSource, под которыми этот сервис появляется в плеере (приложение, вкладка браузера, окно Visor).
    let sourceIDs: [String]
    /// Сервис, который умеет играть в окне Visor, когда приложения нет.
    let web: WebService2?

    var installedURL: URL? {
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        }
        for name in fileNames {
            let path = "/Applications/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Приложение, если оно есть. Иначе сервис открывается в окне Visor (`onWeb`), а без такой возможности на сайте.
    func open(onWeb: (WebService2) -> Void) {
        if let url = installedURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let web {
            onWeb(web)
        } else {
            NSWorkspace.shared.open(site)
        }
    }

    static let all: [MusicApp] = [
        MusicApp(id: "spotify", name: "Spotify", bundleIDs: ["com.spotify.client"], fileNames: ["Spotify"],
                 site: URL(string: "https://open.spotify.com")!, tint: 0x1DB954,
                 sourceIDs: ["spotify", "web-spotify", "own-spotify"], web: .spotify),
        MusicApp(id: "music", name: "Apple Music", bundleIDs: ["com.apple.Music"], fileNames: ["Music"],
                 site: URL(string: "https://music.apple.com")!, tint: 0xFA243C,
                 sourceIDs: ["music", "web-apple"], web: nil),
        MusicApp(id: "yandex", name: "Яндекс Музыка", bundleIDs: ["ru.yandex.desktop.music"], fileNames: ["Яндекс Музыка", "Yandex Music"],
                 site: URL(string: "https://music.yandex.ru")!, tint: 0xFFDD00,
                 sourceIDs: ["yandex-app", "web-yandex", "own-yandex"], web: .yandex),
        MusicApp(id: "ytmusic", name: "YouTube Music", bundleIDs: [], fileNames: [],
                 site: URL(string: "https://music.youtube.com")!, tint: 0xFF0033,
                 sourceIDs: ["web-ytmusic", "own-ytmusic"], web: .ytmusic),
        MusicApp(id: "soundcloud", name: "SoundCloud", bundleIDs: [], fileNames: [],
                 site: URL(string: "https://soundcloud.com")!, tint: 0xFF5500,
                 sourceIDs: ["web-soundcloud", "own-soundcloud"], web: .soundcloud),
    ]
}

struct MusicAppButton: View {
    let app: MusicApp
    /// Выбор сервиса: плеер теперь показывает именно его.
    let onOpenWeb: (WebService2) -> Void
    @State private var hovered = false

    var body: some View {
        let installed = app.installedURL
        Button {
            PlayerController.shared.preferredApp = app.id
            PlayerController.shared.showSources = false
            app.open(onWeb: onOpenWeb)
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let installed {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: installed.path)).resizable().scaledToFit()
                    } else {
                        Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 34, height: 34)
                Text(app.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                Text(installed != nil ? "Открыть" : (app.web != nil ? "В Visor" : "Открыть сайт")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .frame(width: 92, height: 88)
            .background(hovered ? Palette.hover : Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
    }
}
