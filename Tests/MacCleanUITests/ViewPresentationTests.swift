import Testing
import SwiftUI
@testable import MacCleanUI

@Test func whitespaceOnlySearchUsesTheUnfilteredEmptyState() {
    let presentation = CandidateSearchPresentation(query: "  \n\t  ")

    #expect(presentation.normalizedQuery.isEmpty)
    #expect(presentation.emptyTitle == "尚无候选项")
    #expect(presentation.emptyDescription == "从菜单栏运行扫描后，候选项会按风险分组显示。")
}

@Test func riskFilterUsesClearLocalizedLabels() {
    #expect(CandidateRiskFilter.all.title == "全部")
    #expect(CandidateRiskFilter.green.title == "安全")
    #expect(CandidateRiskFilter.yellow.title == "待确认")
    #expect(CandidateRiskFilter.red.title == "仅报告")
}

@Test func filteredEmptyStateExplainsHowToRecover() {
    let presentation = CandidateSearchPresentation(
        query: "",
        filter: .yellow
    )

    #expect(presentation.emptyTitle == "该分类暂无项目")
    #expect(presentation.emptyDescription == "可以切换到其他分类，或重新扫描。")
}

@Test @MainActor func estimatedSpaceTextUsesTheScaledMetricValue() throws {
    let base = ImageRenderer(
        content: EstimatedSpaceScaledText(value: "1 GB", pointSize: 20)
            .fixedSize()
    )
    let scaled = ImageRenderer(
        content: EstimatedSpaceScaledText(value: "1 GB", pointSize: 40)
            .fixedSize()
    )

    let baseHeight = try #require(base.nsImage?.size.height)
    let scaledHeight = try #require(scaled.nsImage?.size.height)

    #expect(scaledHeight > baseHeight)
}
