import AppKit
import Combine
import SwiftUI

/// Classroom timer (计时器): countdown with presets, or a stopwatch.
struct TimerView: View {
    let close: () -> Void

    enum Mode: String, CaseIterable { case countdown = "倒计时", stopwatch = "正计时" }

    @State private var mode: Mode = .countdown
    @State private var total: TimeInterval = 180
    @State private var remaining: TimeInterval = 180
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var lastTick = Date()
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: mode) { _, _ in reset() }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Text(format(mode == .countdown ? remaining : elapsed))
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(mode == .countdown && remaining <= 10 && running ? .red : .primary)
                .frame(minWidth: 260)
            if mode == .countdown && !running {
                HStack {
                    ForEach([30.0, 60, 180, 300, 600], id: \.self) { s in
                        Button(s < 60 ? "\(Int(s))秒" : "\(Int(s / 60))分") { total = s; remaining = s }
                            .buttonStyle(.bordered)
                    }
                }
                HStack {
                    Button { adjust(-60) } label: { Image(systemName: "minus") }
                    Button { adjust(60) } label: { Image(systemName: "plus") }
                    Text("每次 1 分钟").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button(running ? "暂停" : "开始") { running.toggle(); lastTick = Date() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                Button("重置", action: reset).buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .padding(4)
        .fixedSize()
        .onReceive(ticker) { now in
            guard running else { return }
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            if mode == .countdown {
                remaining = max(0, remaining - dt)
                if remaining == 0 {
                    running = false
                    NSSound(named: "Glass")?.play()
                }
            } else {
                elapsed += dt
            }
        }
    }

    private func adjust(_ d: TimeInterval) {
        total = max(10, total + d)
        remaining = total
    }

    private func reset() {
        running = false
        remaining = total
        elapsed = 0
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
