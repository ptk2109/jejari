import SwiftUI

/// 마지막 불러오기 결과 (기획서 12.5 결과 보고)
struct ResultView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = state.lastReport {
                Text(state.lastReportName).font(.title3.bold())
                Text(report.summary)
                List {
                    section("⚠️ 문제", report.problems)
                    section("❌ 찾지 못한 창", report.missing)
                    section("↪︎ 옮긴 창", report.moved)
                    section("다른 앱", report.otherApps)
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
