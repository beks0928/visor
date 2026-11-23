import SwiftUI

/// Устройства Spotify: выбор того, где играть. Песня продолжается с того же места.
struct DevicesScreen: View {
    let player: PlayerController
    var connect: SpotifyConnect = .shared

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Играть на устройстве").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Обновить") { Task { await connect.loadDevices() } }.font(.system(size: 12)).disabled(!connect.signedIn || connect.busy)
                Button { player.showDevices = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        .background(Palette.hover, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
            }
            if connect.signedIn {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(connect.devices.sorted { $0.isPhone && !$1.isPhone }) { device in row(device) }
                    }
                }
                .frame(maxHeight: 150)
            } else {
                Text("Чтобы переносить песню на телефон, войдите в Spotify (нужен Premium). Пароль Visor не видит: вход идёт на сайте Spotify.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button(connect.busy ? "Жду входа…" : "Войти в Spotify") { Task { await connect.signIn() } }.disabled(connect.busy)
            }
            if connect.signedIn {
                Toggle("Переносить песню на телефон, когда Mac засыпает или выключается", isOn: Bindable(connect).autoHandoff)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            if let message = connect.message {
                Text(message).font(.system(size: 11.5)).foregroundStyle(AgentState.waiting.color).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Text("Телефон появляется в списке, когда на нём открыт Spotify с этим же аккаунтом. Для Apple Music такого переноса нет: Apple не даёт управлять им снаружи.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .padding(.horizontal, 6)
        .task { if connect.signedIn { await connect.loadDevices() } }
    }

    private func row(_ device: SpotifyDevice) -> some View {
        Button { Task { await connect.transfer(to: device) } } label: {
            HStack(spacing: 10) {
                Image(systemName: device.symbol).font(.system(size: 16)).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.text)
                    Text(device.isActive ? "Сейчас играет здесь" : (device.isPhone ? "Телефон" : device.type))
                        .font(.system(size: 11)).foregroundStyle(device.isActive ? MediaSource.spotify.color : Palette.muted)
                }
                Spacer()
                if device.isActive { Image(systemName: "speaker.wave.2.fill").foregroundStyle(MediaSource.spotify.color) }
            }
            .padding(.horizontal, 10).frame(height: 44)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressStyle())
    }
}
