import CoreGraphics
import Testing
@testable import MacCleanUI

@Test func fittedContentSizeNeverUndercutsTheWindowMinimum() {
    let fitted = DetailsWindowSizing.fittedContentSize(
        fitting: CGSize(width: 800, height: 500),
        minSize: CGSize(width: 920, height: 640),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    #expect(fitted == CGSize(width: 920, height: 640))
}

@Test func fittedContentSizeClampsToTheVisibleScreen() {
    let fitted = DetailsWindowSizing.fittedContentSize(
        fitting: CGSize(width: 1_600, height: 1_200),
        minSize: CGSize(width: 920, height: 640),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    #expect(fitted == CGSize(width: 1_440, height: 900))
}

@Test func fittedContentSizePassesThroughContentInsideTheVisibleFrame() {
    let fitted = DetailsWindowSizing.fittedContentSize(
        fitting: CGSize(width: 1_100, height: 937),
        minSize: CGSize(width: 920, height: 640),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 1_024)
    )

    #expect(fitted == CGSize(width: 1_100, height: 937))
}
