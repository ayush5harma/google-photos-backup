import AppKit
@testable import PhotosBackup
import SwiftUI
import XCTest

/// The connected-device page has no ScrollView, so the guidance card's
/// minimum height is part of the window's. Measured 2026-10-26: with the
/// paragraph pinned by fixedSize alone, the card's minimum at a zero width --
/// the proposal AppKit uses for a window's minimum size -- was 2,574 points on
/// a 1,409-point screen, and the whole window drew blank: no sidebar rows, no
/// page. Without fixedSize the paragraph was squeezed to one truncated line.
@MainActor
final class ConnectedDeviceGuidanceTests: XCTestCase {
    private func size(_ proposal: CGSize) -> CGSize {
        NSHostingController(rootView: ConnectedDeviceGuidance()).sizeThatFits(in: proposal)
    }

    func testMinimumHeightStaysBoundedAtZeroWidth() {
        XCTAssertLessThan(size(.zero).height, 400)
    }

    /// A paragraph that keeps its lines needs more height as the page
    /// narrows (520 points is about the page at the smallest window); one
    /// squeezed to a truncated line needs the same at any width.
    func testParagraphKeepsItsWrappedLinesAtTheNarrowestPage() {
        let narrow = size(CGSize(width: 520, height: 0)).height
        let wide = size(CGSize(width: 2000, height: 0)).height
        XCTAssertGreaterThan(narrow, wide)
    }
}
