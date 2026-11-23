import AppKit
import Observation
import SwiftUI

enum ToolsSub: String, CaseIterable, Identifiable {
    case line, translate

    var id: String { rawValue }
    var title: String { self == .line ? "Строка" : "Перевод" }
}

/// Вкладка «Инструменты»: одна строка для счёта, процентов, единиц и валют, и перевод.
struct ToolsPage: View {
    let model: IslandModel
    var rates: RatesStore = .shared
    var settings: ToolsSettings = .shared

    private var sub: ToolsSub { model.toolsSub }
    @State private var input = ""
    @State private var copied = false
    @State private var translate = TranslateModel()
    @FocusState private var focused: Bool

    init(model: IslandModel, rates: RatesStore = .shared, settings: ToolsSettings = .shared, translate openTranslate: Bool = false) {
        self.model = model
        self.rates = rates
        self.settings = settings
        if openTranslate { model.toolsSub = .translate }
    }

    private static let examples = ["310$ в тенге", "100 долларов", "5000 тг в евро", "€50 to usd", "2.5к фунтов в рубли",
                                   "15% от 84 000", "84000 + 15%", "12*(3+4)", "5 миль в км", "72 f в c", "180 см в футы"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch sub {
            case .line: lineTool
            case .translate: TranslateTool(model: model, state: translate)
            }
        }
        .task { rates.refreshIfNeeded() }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            // Окно острова неактивное: без этого ввод с клавиатуры уходил бы в другое приложение.
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear { model.keepOpen = false }
    }

    /// Слева вкладки «Строка» и «Перевод», справа, пока открыт перевод, выбор языка.
    private var header: some View {
        HStack(spacing: 2) {
            ForEach(ToolsSub.allCases) { item in
                Button { model.toolsSub = item } label: {
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(sub == item ? Palette.text : Palette.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(sub == item ? Palette.selected : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 12)
            if sub == .translate {
                Text("Перевести на").font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize()
                    .padding(.trailing, 4)
                ForEach(TranslateTarget.allCases) { item in
                    Button { translate.target = item } label: {
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(translate.target == item ? Palette.text : Palette.muted)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(translate.target == item ? Color.white.opacity(0.16) : Palette.card))
                            .overlay(Capsule().stroke(translate.target == item ? Palette.accent : Palette.cardBorder))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(item.hint)
                }
            }
        }
    }

    // MARK: Строка

    private let history = RateHistory.shared

    /// История курса грузится, когда в строке появилась новая пара валют. Смена суммы её не перезагружает.
    private func loadHistory() {
        guard let pair = result?.pair else { return }
        let table = rates.table.perUSD
        let live = table[pair.from].flatMap { from in table[pair.to].map { $0 / from } }
        history.load(pair, live: live)
    }

    private var result: ToolResult? {
        ToolsEngine.evaluate(input, rates: rates.table, defaultCurrency: settings.defaultCurrency)
    }

    private var lineTool: some View {
        VScroll {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Сумма и валюта, единицы, проценты, выражение", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Palette.accent : Palette.cardBorder))
                    .onChange(of: result?.pair?.key) { loadHistory() }
                    .onAppear { loadHistory() }
                resultCard
                currencyRow
                rateInfo
                label("Попробуйте")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Self.examples, id: \.self) { example in
                        Button { input = example } label: {
                            Text(example)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Capsule().fill(Palette.card))
                                .overlay(Capsule().stroke(Palette.cardBorder))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if let result {
            HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.headline).font(.system(size: 22, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
                if let detail = result.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if !result.extras.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(result.extras, id: \.self) {
                            Text($0)
                                .font(.system(size: 11, design: .rounded).monospacedDigit())
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Capsule().fill(Palette.selected))
                        }
                    }
                }
                Text(copied ? "Скопировано" : "Нажмите на результат, чтобы скопировать")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? AgentState.done.color : Palette.muted)
            }
            .layoutPriority(1)
            // Курс валюты рисуется в свободном месте справа. Длинная сумма расширяет текст слева, график сужается и остаётся рядом.
            if let pair = result.pair {
                RateChart(pair: pair, history: history)
                    .frame(minWidth: 190, maxWidth: .infinity)
            }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture {
                ClipboardStore.shared.copyPlain(result.value)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            }
        } else {
            Text("Напишите, например: 310$ в тенге, 15% от 84 000, 5 миль в км или 12*(3+4).")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.vertical, 6)
        }
    }

    private var currencyRow: some View {
        HStack(spacing: 6) {
            Text("Валюта по умолчанию").font(.system(size: 12)).foregroundStyle(Palette.muted)
            ForEach(ToolsSettings.popular, id: \.self) { code in
                Button { settings.setDefaultCurrency(code) } label: {
                    Text(code)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.defaultCurrency == code ? Palette.text : Palette.muted)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Capsule().fill(settings.defaultCurrency == code ? Color.white.opacity(0.16) : Palette.card))
                        .overlay(Capsule().stroke(settings.defaultCurrency == code ? Palette.accent : Palette.cardBorder))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(ToolsSettings.more.filter { rates.table.perUSD[$0] != nil }, id: \.self) { code in
                    Button(code) { settings.setDefaultCurrency(code) }
                }
            } label: {
                Text(ToolsSettings.popular.contains(settings.defaultCurrency) ? "Ещё" : settings.defaultCurrency)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var rateInfo: some View {
        HStack(spacing: 8) {
            Text(rateText).font(.system(size: 11)).foregroundStyle(rates.lastError == nil ? Palette.muted : AgentState.waiting.color)
            Button { Task { await rates.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(rates.isRefreshing)
            .accessibilityLabel("Обновить курсы")
        }
    }

    private var rateText: String {
        if let error = rates.lastError { return error }
        if rates.isRefreshing { return "Обновляю курсы…" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return "Курсы на \(formatter.string(from: rates.table.updated)) · open.er-api.com, обновляются раз в час"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.top, 4)
    }
}

// MARK: Перевод

enum TranslateTarget: String, CaseIterable, Identifiable {
    case auto, english, russian, german, french, spanish, turkish, chinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .english: "English"
        case .russian: "Русский"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .turkish: "Türkçe"
        case .chinese: "中文"
        }
    }

    var hint: String {
        self == .auto ? "Русский текст переводится на английский, любой другой на русский" : "Перевести на этот язык"
    }

    var code: String? {
        switch self {
        case .auto: nil
        case .english: "en"
        case .russian: "ru"
        case .german: "de"
        case .french: "fr"
        case .spanish: "es"
        case .turkish: "tr"
        case .chinese: "zh-Hans"
        }
    }
}

/// Состояние перевода. Переводит Google Переводчик, текст уходит в сеть.
@MainActor @Observable
final class TranslateModel {
    enum Status: Equatable {
        case idle, working
        case failed(String)
    }

    var text = ""
    var output = ""
    var status: Status = .idle
    var target: TranslateTarget = .auto

    /// Язык текста по буквам: кириллица это русский, остальное считается английским.
    /// Нужен только для «Авто»: сам Google язык определяет по всему тексту.
    var sourceLanguage: Locale.Language {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return Locale.Language(identifier: cyrillic ? "ru" : "en")
    }

    /// «Авто»: русский переводится на английский, всё остальное на русский.
    var targetLanguage: Locale.Language {
        if let code = target.code { return Locale.Language(identifier: code) }
        return Locale.Language(identifier: sourceLanguage.minimalIdentifier == "ru" ? "en" : "ru")
    }

    /// Код языка для Google: китайский упрощённый у него «zh-CN».
    var googleCode: String {
        let code = targetLanguage.minimalIdentifier
        return code.hasPrefix("zh") ? "zh-CN" : code
    }

    static func name(_ language: Locale.Language) -> String {
        Locale(identifier: "ru").localizedString(forLanguageCode: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}

struct TranslateTool: View {
    let model: IslandModel
    let state: TranslateModel

    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Bindable(state).text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(8)
                if state.text.isEmpty {
                    Text("Введите текст. Русский переводится на английский, остальное на русский. Другой язык выбирается кнопками сверху.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Palette.accent : Palette.cardBorder))
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 260)
            outputPanel
        }
        .onChange(of: state.text) { _, _ in retranslate() }
        .onChange(of: state.target) { _, _ in retranslate() }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            // Окно острова неактивное: без этого ввод с клавиатуры уходил бы в другое приложение.
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear { model.keepOpen = false }
    }

    // MARK: Правая часть

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(state.output.isEmpty ? " " : state.output)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
            statusView
            if !state.output.isEmpty {
                Button("Скопировать перевод") { ClipboardStore.shared.copyPlain(state.output) }.buttonStyle(VisorButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.status {
        case .idle:
            Text("Переводит Google Переводчик: текст отправляется в сеть.").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        case .working:
            Text("Перевожу…").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.system(size: 11.5)).foregroundStyle(AgentState.waiting.color)
                Button("Повторить") { retranslate() }.buttonStyle(VisorButtonStyle())
            }
        }
    }

    // MARK: Запуск перевода

    /// Перевод запускается через 0,6 секунды после последней буквы. Устаревший ответ отбрасывается.
    private func retranslate() {
        pending?.cancel()
        let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state.output = ""
            state.status = .idle
            return
        }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            state.status = .working
            let code = state.googleCode
            do {
                let result = try await GoogleTranslate.translate(text, to: code)
                guard !Task.isCancelled else { return }
                state.output = result.text
                state.status = .idle
            } catch GoogleTranslate.Failure.format {
                guard !Task.isCancelled else { return }
                state.status = .failed("Google ответил не так, как ожидалось. Возможно, он изменил адрес перевода.")
            } catch {
                guard !Task.isCancelled else { return }
                state.status = .failed("Нет связи с Google. Проверьте интернет и нажмите «Повторить».")
            }
        }
    }
}
