import CleanCore
import Foundation
import SwiftUI

struct CandidateSearchPresentation {
    let query: String

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var emptyTitle: String {
        normalizedQuery.isEmpty ? "尚无候选项" : "没有匹配的候选项"
    }

    var emptyDescription: String {
        normalizedQuery.isEmpty
            ? "从菜单栏运行扫描后，候选项会按风险分组显示。"
            : "请尝试其他名称、路径、来源或规则。"
    }
}

@MainActor
public struct DetailView: View {
    @Bindable private var model: AppModel
    @State private var searchText = ""

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                if filteredCandidates.isEmpty {
                    ContentUnavailableView {
                        Label(searchPresentation.emptyTitle, systemImage: "magnifyingglass")
                    } description: {
                        Text(searchPresentation.emptyDescription)
                    }
                } else {
                    candidateList
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "搜索名称、路径、来源或规则"
        )
        .safeAreaInset(edge: .bottom) {
            cleanupBar
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("候选项详情")
                        .font(.title2.weight(.semibold))
                    Text("\(formattedEstimatedBytes) 预计可释放")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("预计可释放空间 \(formattedEstimatedBytes)")
                }
                Spacer()
                phaseIndicator
            }

            if let errorMessage = model.state.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("操作失败：\(errorMessage)")
            }

            if !model.state.failures.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(
                            Array(model.state.failures.enumerated()),
                            id: \.offset
                        ) { _, failure in
                            LabeledContent(failure.scannerID, value: failure.message)
                                .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label(
                        "\(model.state.failures.count) 个扫描器未完成",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        }
        .padding(20)
    }

    private var candidateList: some View {
        List {
            ForEach(RiskLevel.allCases, id: \.self) { risk in
                let candidates = filteredCandidates.filter { $0.risk == risk }
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { candidate in
                            CandidateRow(candidate: candidate, model: model)
                        }
                    } header: {
                        Label(riskTitle(risk), systemImage: riskSymbol(risk))
                            .accessibilityLabel("风险分组：\(riskTitle(risk))")
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var cleanupBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("仅清理安全缓存")
                    .font(.headline)
                Text("黄色项目需要确认；红色项目不会执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.cleanGreenCandidates() }
            } label: {
                if model.state.phase == .scanning {
                    Label("正在扫描…", systemImage: "magnifyingglass")
                } else if model.state.phase == .cleaning {
                    Label("正在清理…", systemImage: "trash")
                } else {
                    Label("清理安全缓存", systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCleanupDisabled)
            .accessibilityHint(cleanupAccessibilityHint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch model.state.phase {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在扫描候选项…")
            }
            .foregroundStyle(.secondary)
        case .cleaning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在清理安全缓存…")
            }
            .foregroundStyle(.secondary)
        case .idle, .results:
            EmptyView()
        }
    }

    private var filteredCandidates: [CleanupCandidate] {
        let query = searchPresentation.normalizedQuery
        guard !query.isEmpty else { return model.state.candidates }

        return model.state.candidates.filter { candidate in
            searchableValues(for: candidate).contains {
                $0.localizedStandardContains(query)
            }
        }
    }

    private func searchableValues(for candidate: CleanupCandidate) -> [String] {
        [
            candidate.displayName,
            candidate.sourceURL.path,
            candidate.canonicalURL.path,
            candidate.evidence.ownerName,
            candidate.evidence.ownerBundleID,
            candidate.evidence.scannerID,
            candidate.evidence.ruleID,
            candidate.evidence.explanation,
            candidate.riskReason,
            candidate.evidence.commandPreview
        ].compactMap { $0 }
    }

    private var greenCandidateCount: Int {
        model.state.candidates.count { $0.risk == .green }
    }

    private var isCleanupDisabled: Bool {
        model.state.phase == .scanning
            || model.state.phase == .cleaning
            || greenCandidateCount == 0
    }

    private var cleanupAccessibilityHint: String {
        switch model.state.phase {
        case .scanning: "扫描完成后才能清理。"
        case .cleaning: "安全缓存清理正在进行。"
        case .idle: "请先扫描，再清理安全缓存。"
        case .results where greenCandidateCount == 0: "当前没有可清理的安全缓存。"
        case .results: "只执行标记为安全缓存的绿色候选项。"
        }
    }

    private var formattedEstimatedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: model.estimatedReclaimableBytes),
            countStyle: .file
        )
    }

    private var searchPresentation: CandidateSearchPresentation {
        CandidateSearchPresentation(query: searchText)
    }

    private func riskTitle(_ risk: RiskLevel) -> String {
        switch risk {
        case .green: "安全缓存"
        case .yellow: "需要确认"
        case .red: "仅报告"
        }
    }

    private func riskSymbol(_ risk: RiskLevel) -> String {
        switch risk {
        case .green: "checkmark.shield"
        case .yellow: "exclamationmark.triangle"
        case .red: "hand.raised"
        }
    }
}
