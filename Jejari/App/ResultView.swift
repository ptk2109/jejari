import SwiftUI

/// 마지막 불러오기 결과 (기획서 12.5 결과 보고)
struct ResultView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = state.lastReport {
                Text(state.lastReportName).font(.title3.bold())
                Text(report.summary)
                if !state.lateWaiting.isEmpty {
                    HStack {
                        Text("늦게 뜬 창 \(state.lateWaiting.count)개: \(state.lateWaiting.joined(separator: ", "))")
                        Spacer()
                        Button("제자리로 옮기기") { state.placeLateWindows() }
                            .disabled(state.busy)
                    }
                    Text("가상화면을 바꿔야 옮길 수 있어서 누를 때까지 기다리고 있어요.").font(.caption).foregroundStyle(.secondary)
                }
                List {
                    section("⚠️ 문제", report.problems)
                    section("❌ 찾지 못한 창", report.missing)
                    section("↪︎ 옮긴 창", report.moved)
                    section("다른 앱", report.otherApps)
                    section("가상화면 정리", report.spaces)
                }
                if report.problems.isEmpty && report.missing.isEmpty {
                    Text("모든 창이 제자리입니다.").foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("아직 불러오기 결과가 없습니다", systemImage: "tray")
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }

    @ViewBuilder
    private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            Section(title) {
                ForEach(lines, id: \.self) { Text($0).textSelection(.enabled) }
            }
        }
    }
}
