import AppKit
import SwiftUI

private func filesWord(_ n: Int) -> String {
    let tens = n % 100, ones = n % 10
    if tens > 10 && tens < 20 { return "файлов" }
    switch ones {
    case 1: return "файл"
    case 2...4: return "файла"
    default: return "файлов"
    }
}

/// Вкладка «Полка»: карточки с файлами, выбор, удаление и перетаскивание наружу.
struct ShelfPage: View {
    let model: IslandModel
    var store: ShelfStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Полка").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(store.items.count) \(filesWord(store.items.count)) · снимки экрана попадают сюда сами и не удаляются")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            if !store.selection.isEmpty {
                HStack(spacing: 8) {
                    Text("Выбрано \(store.selection.count). Перетащите любую выбранную карточку").font(.system(size: 12))
                    Spacer()
                    Button("Удалить выбранные") { store.removeSelected() }.buttonStyle(VisorButtonStyle(kind: .danger))
                    Button("Снять") { store.selection = [] }.buttonStyle(VisorButtonStyle())
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Palette.selected, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent))
            } else if !store.items.isEmpty {
                Text("Клик выбирает карточку, двойной клик открывает, Shift+клик добавляет к выбору. Крестик на карточке удаляет её.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Text("Полка пуста").font(.system(size: 13, weight: .medium))
                    Text("Перетащите файл на остров или сделайте снимок экрана: он появится здесь.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            } else {
                VScroll {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(store.items) { ShelfCard(item: $0, store: store) }
                    }
                }
            }
        }
    }
}

struct ShelfCard: View {
    let item: ShelfItem
    let store: ShelfStore
    @State private var image: NSImage?
    @Environment(\.snapshotMode) private var snapshotMode

    init(item: ShelfItem, store: ShelfStore) {
        self.item = item
        self.store = store
        _image = State(initialValue: store.cachedThumbnail(for: item))
    }

    var body: some View {
        let selected = store.selection.contains(item.id)
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 5) {
                // Клетка одного размера у всех карточек. Фото заполняет её и обрезается по ней же, а не по своей рамке:
                // иначе широкие и высокие снимки вылезали за карточку и наползали на соседние.
                Color.white.opacity(0.16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .overlay {
                        if let image { Image(nsImage: image).resizable().scaledToFill() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.accent : Palette.cardBorder, lineWidth: selected ? 2 : 1))
            .allowsHitTesting(false)

            if !snapshotMode { ShelfDragSource(id: item.id) }

            Button { store.remove([item.id]) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.75), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить \(item.name)")
            .padding(10)
        }
        .frame(height: 100)
        .task(id: item.id) { image = await store.thumbnail(for: item) }
    }
}

/// Прозрачный слой поверх карточки: клик выбирает, перетаскивание уносит файлы в любое приложение.
/// Если тащат выбранную карточку, уходят все выбранные.
struct ShelfDragSource: NSViewRepresentable {
    let id: UUID

    func makeNSView(context: Context) -> ShelfDragView { ShelfDragView(id: id) }
    func updateNSView(_ view: ShelfDragView, context: Context) { view.id = id }
}

final class ShelfDragView: NSView, NSDraggingSource {
    var id: UUID
    private var mouseDownEvent: NSEvent?

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    // Окно острова не активное: первый клик должен работать сразу.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                             event.locationInWindow.y - down.locationInWindow.y)
        guard distance > 4 else { return }
        mouseDownEvent = nil
        beginDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        // Двойной клик открывает файл в программе по умолчанию (снимок откроется в «Просмотре»).
        if event.clickCount >= 2 {
            ShelfStore.shared.open(id)
            return
        }
        ShelfStore.shared.select(id, extend: event.modifierFlags.contains(.shift))
    }

    private func beginDrag(with event: NSEvent) {
        let entries = ShelfStore.shared.dragURLs(starting: id)
        guard !entries.isEmpty else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = entries.enumerated().map { index, entry in
            let item = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
            let image = ShelfStore.shared.cachedThumbnail(for: entry.item) ?? NSWorkspace.shared.icon(forFile: entry.url.path)
            let shift = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: origin.x - 40 + shift, y: origin.y - 30 - shift, width: 80, height: 60), contents: image)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
