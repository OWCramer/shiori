import LucaKit
import SwiftUI

/// Shiori's saves for Luca System games: `saves/luca-NN.json` (the player's state, the line
/// on screen and the date) with `luca-NN.jpg`. Slot 0 is the autosave made on leaving.
enum LucaSaves {
    struct Save: Codable {
        var date: Date
        var text: String
        var state: LucaPlayer.State
    }

    static func url(slot: Int, in folder: URL, ext: String = "json") -> URL {
        folder.appendingPathComponent(String(format: "luca-%02d.%@", slot, ext))
    }

    static func write(_ state: LucaPlayer.State, slot: Int, thumbnail: Data?, in folder: URL) throws {
        let text = state.message.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text } ?? ""
        let data = try JSONEncoder().encode(Save(date: .now, text: text, state: state))
        try data.write(to: url(slot: slot, in: folder), options: .atomic)
        if let thumbnail { try? thumbnail.write(to: url(slot: slot, in: folder, ext: "jpg"), options: .atomic) }
    }

    static func read(slot: Int, in folder: URL) -> Save? {
        guard let data = try? Data(contentsOf: url(slot: slot, in: folder)) else { return nil }
        return try? JSONDecoder().decode(Save.self, from: data)
    }

    static func latest(in folder: URL) -> Save? {
        ((0...slotCount) + [quickSlot]).compactMap { read(slot: $0, in: folder) }.max { $0.date < $1.date }
    }

    static let slotCount = 30
    /// Q.SAVE / Q.LOAD's slot, apart from the numbered ones.
    static let quickSlot = 99
}

private let lucaBlue = Color(red: 0.25, green: 0.56, blue: 0.93)

struct LucaTitleView: View {
    let background: CGImage?
    let logo: CGImage?
    let canContinue: Bool
    let onNewGame: () -> Void
    let onContinue: () -> Void
    let onLoad: () -> Void
    let onLeave: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let background {
                    Image(decorative: background, scale: 1).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                VStack(spacing: proxy.size.height * 0.05) {
                    if let logo {
                        Image(decorative: logo, scale: 1).resizable().scaledToFit()
                            .frame(width: proxy.size.width * 0.55)
                            .shadow(color: lucaBlue.opacity(0.6), radius: 12)
                    }
                    VStack(spacing: 10) {
                        if canContinue { button("Continue", action: onContinue) }
                        button("New Game", action: onNewGame)
                        button("Load", action: onLoad)
                        button("Leave", action: onLeave)
                    }
                }
                .padding(.top, proxy.size.height * 0.06)
            }
        }
        .ignoresSafeArea()
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .tracking(3)
                .foregroundStyle(.white)
                .frame(width: 220, height: 40)
        }
        .glassEffect(.regular.tint(lucaBlue.opacity(0.35)).interactive(), in: .capsule)
    }
}

struct LucaSlotsView: View {
    let folder: URL
    let saving: Bool
    let onPick: (Int) -> Void
    let onClose: () -> Void
    @State private var saves: [Int: LucaSaves.Save] = [:]

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.75)).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Text(saving ? "Save" : "Load").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                    Button("Close", action: onClose).buttonStyle(.glass)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(saving ? Array(1...LucaSaves.slotCount) : Array(0...LucaSaves.slotCount), id: \.self) { slot in
                            if saving || saves[slot] != nil { tile(slot) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            saves = Dictionary(uniqueKeysWithValues: (0...LucaSaves.slotCount).compactMap { slot in
                LucaSaves.read(slot: slot, in: folder).map { (slot, $0) }
            })
        }
    }

    private func tile(_ slot: Int) -> some View {
        Button { onPick(slot) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    if let image = UIImage(contentsOfFile: LucaSaves.url(slot: slot, in: folder, ext: "jpg").path), saves[slot] != nil {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Text("Empty").foregroundStyle(.white.opacity(0.5))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(slot == 0 ? "Autosave" : "Slot \(slot)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                if let save = saves[slot] {
                    Text(save.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    Text(save.text).font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct LucaBacklogView: View {
    let lines: [LucaMessage]
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.8)).ignoresSafeArea()
                .onTapGesture(perform: onClose)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            VStack(alignment: .leading, spacing: 2) {
                                if let speaker = line.speaker {
                                    Text(speaker).font(.subheadline.weight(.bold)).foregroundStyle(lucaBlue)
                                }
                                Text(line.text).font(.body).foregroundStyle(.white)
                            }
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 30)
                }
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Close", action: onClose).buttonStyle(.glass).padding(16)
                }
                Spacer()
            }
        }
        .gesture(DragGesture().onEnded { value in if value.translation.height < -80 { onClose() } })
    }
}
