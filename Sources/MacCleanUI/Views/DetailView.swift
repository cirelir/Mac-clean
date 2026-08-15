import AppKit
import CleanCore
import Foundation
import SwiftUI

enum CandidateRiskFilter: String, CaseIterable, Identifiable {
    case all, green, yellow, red

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .green: "安全"
        case .yellow: "待确认"
        case .red: "仅报告"
        }
    }

    var risk: RiskLevel? {
        switch self {
        case .all: nil
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    func includes(_ candidate: CleanupCandidate) -> Bool {
        risk == nil || candidate.risk == risk
    }
}

struct CandidateSearchPresentation {
    let query: String
    let filter: CandidateRiskFilter

    init(query: String, filter: CandidateRiskFilter = .all) {
        self.query = query
        self.filter = filter
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var emptyTitle: String {
        if !normalizedQuery.isEmpty {
            return "没有匹配的候选项"
        }
        return filter == .all ? "尚无候选项" : "该分类暂无项目"
    }

    var emptyDescription: String {
        if !normalizedQuery.isEmpty {
            return "请尝试其他名称、路径、来源或规则。"
        }
        if filter == .all {
            return "从菜单栏运行扫描后，候选项会按风险分组显示。"
        }
        return "可以切换到其他分类，或重新扫描。"
    }
}

private struct CandidateSection: Identifiable {
    let risk: RiskLevel
    let candidates: [CleanupCandidate]

    var id: RiskLevel { risk }
}

@MainActor
public struct DetailView: View {
    @Bindable private var model: AppModel
    @Environment(AppearanceStore.self) private var appearanceStore
    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var riskFilter: CandidateRiskFilter = .all
    @State private var applicationIcons: [UUID: NSImage] = [:]

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let sections = candidateSections

        VStack(spacing: 0) {
            header

            filterBar

            Divider()

            Group {
                if sections.isEmpty {
                    emptyState
                } else {
                    candidateContent(sections)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(.blue)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            cleanupBar
        }
        .onChange(of: model.state.candidates) { _, newCandidates in
            let validIDs = Set(newCandidates.map(\.id))
            selectedIDs = selectedIDs.intersection(validIDs)
        }
        .task(id: candidateIDs) {
            await resolveApplicationIcons()
        }
        .frame(
            minWidth: 920,
            idealWidth: 1_100,
            minHeight: 640,
            idealHeight: contentIdealHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(appearanceStore.preference.colorScheme)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 38) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("可释放")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                        Text(formattedPotentialBytes)
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("预计可释放空间")
                    .accessibilityValue(formattedPotentialBytes)

                    Label(scanStatusText, systemImage: scanStatusSymbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)

                Button {
                    Task { await model.scan() }
                } label: {
                    Label(scanButtonTitle, systemImage: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: 148)
                .disabled(isBusy)
                .help("重新扫描；关闭本窗口不会中断扫描进程")

                Button {
                    Task { await model.cleanGreenCandidates() }
                } label: {
                    Label(safeCleanupButtonTitle, systemImage: "trash")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(width: 196)
                .disabled(isBusy || greenCandidates.isEmpty)
                .accessibilityHint("仅清理绿色安全缓存。")
            }

            summaryStrip

            if let errorMessage = model.state.errorMessage {
                statusMessage(
                    errorMessage,
                    symbol: "exclamationmark.circle",
                    color: .red
                )
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
                    .padding(.top, 6)
                } label: {
                    Label(
                        "\(model.state.failures.count) 个扫描器未完成",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if !model.state.lastCleanupOutcomes.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(
                            Array(model.state.lastCleanupOutcomes.enumerated()),
                            id: \.offset
                        ) { _, outcome in
                            Text(outcome)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label(
                        "上次清理结果（\(model.state.lastCleanupOutcomes.count) 项）",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .padding(.bottom, 22)
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            RiskSummaryMetric(
                title: "安全缓存",
                value: formattedBytes(greenBytes),
                count: greenCandidates.count,
                symbol: "checkmark.shield.fill",
                color: .green
            )

            summaryDivider

            RiskSummaryMetric(
                title: "需要确认",
                value: formattedBytes(yellowBytes),
                count: yellowCandidates.count,
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )

            summaryDivider

            RiskSummaryMetric(
                title: "仅报告",
                value: formattedBytes(redBytes),
                count: redCandidates.count,
                symbol: "info.circle.fill",
                color: .secondary
            )
        }
        .frame(maxWidth: .infinity, idealHeight: 76, maxHeight: 76)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private var summaryDivider: some View {
        Divider()
            .padding(.vertical, 2)
    }

    private var filterBar: some View {
        HStack(spacing: 18) {
            Picker("风险筛选", selection: $riskFilter) {
                ForEach(CandidateRiskFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            // Segmented pickers reserve a ~60pt slot for the picker label even
            // though the style never draws it, which pushes the control off the
            // leading edge. Hiding the label keeps the control flush with the
            // list container below; the accessibility label is re-applied.
            .labelsHidden()
            .accessibilityLabel("风险筛选")
            .frame(width: 520, alignment: .leading)

            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("搜索项目", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 370, height: 36)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private func candidateContent(_ sections: [CandidateSection]) -> some View {
        VStack(spacing: 0) {
            candidateListHeader

            Divider()

            candidateList(sections)
                .frame(
                    idealHeight: candidateListIdealHeight(sections),
                    maxHeight: candidateListIdealHeight(sections)
                )
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    private var candidateListHeader: some View {
        HStack(spacing: 12) {
            Text("项目")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小")
                .frame(width: 94, alignment: .trailing)
            Text("风险级别")
                .frame(width: 112, alignment: .center)
            Text("操作")
                .frame(width: 96, alignment: .center)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 42)
        .padding(.trailing, 18)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .frame(maxWidth: .infinity)
    }

    private func candidateList(_ sections: [CandidateSection]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.candidates) { candidate in
                            CandidateRow(
                                candidate: candidate,
                                applicationIcon: applicationIcons[candidate.id],
                                selection: $selectedIDs,
                                onReveal: { model.reveal(candidate) }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                Divider()
                                    .padding(.leading, 52)
                            }
                        }
                    } header: {
                        RiskSectionHeader(
                            risk: section.risk,
                            count: section.candidates.count
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(alignment: .bottom) {
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func candidateListIdealHeight(_ sections: [CandidateSection]) -> CGFloat {
        let rowCount = sections.reduce(0) { $0 + $1.candidates.count }
        let contentHeight = CGFloat(rowCount) * 65
            + CGFloat(sections.count) * 28
        return min(max(contentHeight, 180), 520)
    }

    /// Ideal window height for the current content, so the details window can
    /// auto-size to what is actually displayed instead of a fixed height.
    ///
    /// The values mirror the layout metrics below: header top/bottom padding
    /// (38/22), header spacing (38), the headline row (~84), the summary strip
    /// (76 + 16 vertical padding = 108), filter bar (36 + 14 + 14 = 64), the
    /// divider (1), the list container chrome (33 header + 1 divider + 16
    /// bottom padding = 50), and the cleanup footer (~58).
    private var contentIdealHeight: CGFloat {
        var headerHeight: CGFloat = 84 + 38 + 108
        if model.state.errorMessage != nil {
            headerHeight += 38 + 18
        }
        if !model.state.failures.isEmpty {
            headerHeight += 38 + disclosureIdealHeight(lineCount: model.state.failures.count)
        }
        if !model.state.lastCleanupOutcomes.isEmpty {
            headerHeight += 38 + disclosureIdealHeight(lineCount: model.state.lastCleanupOutcomes.count)
        }
        headerHeight += 38 + 22

        let contentHeight = candidateSections.isEmpty
            ? 210 // empty-state placeholder (ContentUnavailableView)
            : 50 + candidateListIdealHeight(candidateSections)

        return max(
            640,
            headerHeight + 64 + 1 + contentHeight + 58
        )
    }

    private func disclosureIdealHeight(lineCount: Int) -> CGFloat {
        let visibleLines = CGFloat(min(max(lineCount, 0), 4))
        return 20 + 6 + visibleLines * 15
    }

    private var candidateIDs: [UUID] {
        model.state.candidates.map(\.id)
    }

    private func resolveApplicationIcons() async {
        var resolved: [UUID: NSImage] = [:]

        for candidate in model.state.candidates {
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let icon = ApplicationIconCache.shared.icon(
                for: candidate.evidence.ownerBundleID
            ) {
                resolved[candidate.id] = icon
            }
        }

        applicationIcons = resolved
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(searchPresentation.emptyTitle, systemImage: emptyStateSymbol)
        } description: {
            Text(searchPresentation.emptyDescription)
        } actions: {
            if riskFilter != .all || !searchText.isEmpty {
                Button("显示全部") {
                    riskFilter = .all
                    searchText = ""
                }
            }
        }
    }

    private var cleanupBar: some View {
        HStack(spacing: 18) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cleanupBarTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text("待确认项目将移入废纸篓；仅报告项目不会执行。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
            }

            Spacer()

            if !selectedIDs.isEmpty {
                Text("预计释放 \(formattedSelectedCleanupBytes)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                let confirmedIDs = selectedIDs
                selectedIDs = []
                Task { await model.clean(candidateIDs: confirmedIDs) }
            } label: {
                Label(selectionButtonTitle, systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .disabled(selectionCleanupDisabled)
            .accessibilityHint(selectionCleanupAccessibilityHint)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func statusMessage(
        _ message: String,
        symbol: String,
        color: Color
    ) -> some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
    }

    private var filteredCandidates: [CleanupCandidate] {
        let query = searchPresentation.normalizedQuery
        return model.state.candidates.filter { candidate in
            guard riskFilter.includes(candidate) else { return false }
            guard !query.isEmpty else { return true }
            return searchableValues(for: candidate).contains {
                $0.localizedStandardContains(query)
            }
        }
    }

    private var candidateSections: [CandidateSection] {
        let candidates = filteredCandidates
        return RiskLevel.allCases.compactMap { risk in
            let matches = candidates.filter { $0.risk == risk }
            guard !matches.isEmpty else { return nil }
            return CandidateSection(risk: risk, candidates: matches)
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

    private var greenCandidates: [CleanupCandidate] {
        model.state.candidates.filter { $0.risk == .green }
    }

    private var yellowCandidates: [CleanupCandidate] {
        model.state.candidates.filter { $0.risk == .yellow }
    }

    private var redCandidates: [CleanupCandidate] {
        model.state.candidates.filter { $0.risk == .red }
    }

    private var greenBytes: UInt64 { totalBytes(in: greenCandidates) }
    private var yellowBytes: UInt64 { totalBytes(in: yellowCandidates) }
    private var redBytes: UInt64 { totalBytes(in: redCandidates) }

    private var potentialBytes: UInt64 {
        addingWithoutOverflow(greenBytes, yellowBytes)
    }

    private var selectedYellowBytes: UInt64 {
        totalBytes(
            in: yellowCandidates.filter { selectedIDs.contains($0.id) }
        )
    }

    private var selectedCleanupBytes: UInt64 {
        addingWithoutOverflow(greenBytes, selectedYellowBytes)
    }

    private func totalBytes(in candidates: [CleanupCandidate]) -> UInt64 {
        candidates.reduce(0) { total, candidate in
            addingWithoutOverflow(total, candidate.sizeBytes)
        }
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .file
        )
    }

    private var formattedPotentialBytes: String {
        formattedBytes(potentialBytes)
    }

    private var formattedSelectedCleanupBytes: String {
        formattedBytes(selectedCleanupBytes)
    }

    private var isBusy: Bool {
        model.state.phase == .scanning || model.state.phase == .cleaning
    }

    private var scanButtonTitle: String {
        model.state.phase == .scanning ? "正在扫描…" : "重新扫描"
    }

    private var safeCleanupButtonTitle: String {
        switch model.state.phase {
        case .scanning: "正在扫描…"
        case .cleaning: "正在清理…"
        case .idle, .results: "清理安全缓存"
        }
    }

    private var scanStatusText: String {
        switch model.state.phase {
        case .scanning: "正在检查受支持的系统位置…"
        case .cleaning: "正在执行已验证的清理计划…"
        case .idle: "尚未扫描，清理前会验证每个项目"
        case .results: "已完成扫描，所有项目均经过安全分类"
        }
    }

    private var scanStatusSymbol: String {
        switch model.state.phase {
        case .scanning: "magnifyingglass"
        case .cleaning: "trash"
        case .idle: "shield"
        case .results: "checkmark.shield"
        }
    }

    private var cleanupBarTitle: String {
        selectedIDs.isEmpty
            ? "选择待确认项目后再清理"
            : "已选择 \(selectedIDs.count) 项"
    }

    private var selectionButtonTitle: String {
        selectedIDs.isEmpty
            ? "清理所选"
            : "清理所选（\(selectedIDs.count) 项）"
    }

    private var selectionCleanupDisabled: Bool {
        isBusy || selectedIDs.isEmpty
    }

    private var selectionCleanupAccessibilityHint: String {
        switch model.state.phase {
        case .scanning: "扫描完成后才能清理。"
        case .cleaning: "清理正在进行。"
        case .idle:
            "请先扫描，再勾选黄色待确认项目。"
        case .results where selectedIDs.isEmpty:
            "请先勾选黄色待确认项目。"
        case .results:
            "将清理安全缓存，并把所选项目移入废纸篓。"
        }
    }

    private var searchPresentation: CandidateSearchPresentation {
        CandidateSearchPresentation(query: searchText, filter: riskFilter)
    }

    private var emptyStateSymbol: String {
        searchPresentation.normalizedQuery.isEmpty
            ? "tray"
            : "magnifyingglass"
    }
}

private struct RiskSummaryMetric: View {
    let title: String
    let value: String
    let count: Int
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text("\(count) 项")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .accessibilityElement(children: .combine)
    }
}

private struct RiskSectionHeader: View {
    let risk: RiskLevel
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text("\(count) 项")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 5)
    }

    private var title: String {
        switch risk {
        case .green: "安全缓存"
        case .yellow: "需要确认"
        case .red: "仅报告"
        }
    }

    private var detail: String {
        switch risk {
        case .green: "可直接清理"
        case .yellow: "将移入废纸篓"
        case .red: "不会执行"
        }
    }

    private var symbol: String {
        switch risk {
        case .green: "checkmark.shield.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "info.circle.fill"
        }
    }

    private var color: Color {
        switch risk {
        case .green: .green
        case .yellow: .orange
        case .red: .secondary
        }
    }
}
