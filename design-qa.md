# Mac Clean Redesign QA

- Source visual truth: `/Users/kale/Documents/mac clean/docs/design/mac-clean-redesign-selected.png`
- Baseline after the user's mismatch report: `/Users/kale/Documents/mac clean/docs/design/audit/01-current-results.png`
- Corrected implementation: `/Users/kale/Documents/mac clean/docs/design/mac-clean-redesign-implementation.png`
- Side-by-side evidence: `/Users/kale/Documents/mac clean/docs/design/mac-clean-redesign-comparison.png`
- Viewport: native macOS content surface, 1440 x 1024 points, light appearance
- State: completed scan, all-risk filter, empty search, three green candidates, two yellow candidates, one report-only candidate

## User-reported issues

The previous QA conclusion was incorrect. The user correctly identified two material problems:

1. The implementation did not match the selected concept closely enough. It used an edge-to-edge list, smaller controls, denser header spacing, persistent path-heavy rows, and omitted the concept's rounded table container and action column.
2. Scrolling had avoidable work in the row path. Rows performed application-icon discovery and Finder/file-system availability checks as they appeared, while grouping/filtering work was repeated during view evaluation.

## Corrections

- Rebuilt the results surface as a rounded, bordered table with explicit item, size, risk, and action columns.
- Matched the concept's larger hero spacing, button proportions, summary icons and values, wider segmented filter, wider search field, status symbols, grouped headers, row separators, and fixed safety footer.
- Removed persistent file paths from collapsed rows; full evidence remains available in disclosure details.
- Replaced the eager native list with `ScrollView` + `LazyVStack` and pinned risk-section headers.
- Pre-resolved and cached application icons once per candidate set instead of looking them up while rows scroll into view.
- Deferred Finder/file-system availability checks until a row is expanded, refreshing only when the expanded row returns active.
- Narrowed each row's observation dependency by passing a reveal closure instead of observing the full app model.
- Computed filtered candidate sections once per body evaluation and reused stored row presentation values.

## Visual comparison

The corrected implementation now follows the same full-screen hierarchy as the selected concept: large releasable-space headline, paired top actions, three semantic summary metrics, segmented risk filter, search, a single rounded grouped table, aligned size/risk/action columns, selectable yellow rows, and a pinned safety footer.

Remaining differences are intentional or platform-derived:

- The implementation uses native macOS segmented-control styling rather than the generated mock's custom pale-blue segment.
- The releasable total is 12.5 GB because report-only bytes are excluded; the generated concept displayed 12.8 GB.
- Fixture names and installed application icons differ where the runtime has authoritative data.
- The source image includes generated window chrome; the implementation snapshot captures app-owned content.

No actionable P0, P1, or P2 visual mismatch remains in the corrected side-by-side review.

## Verification

- SwiftUI snapshot at 1440 x 1024: passed in 0.257 seconds.
- Complete Swift test suite: 147 tests passed.
- `git diff --check`: passed.
- Added coverage proving Finder availability checks can remain deferred until disclosure expansion.

The scroll conclusion is code-backed rather than trace-backed: the identified synchronous per-row hot paths are removed, but no Instruments frame-time trace has yet been captured on the user's machine.

final result: passed
