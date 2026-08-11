# Task 1 Report: Swift Package Boundaries and Candidate Contract

## Implementation

- Created the Swift 6.2 macOS 14 package with `CleanCore`, `MacCleanUI`, and `MacCleanApp` products and their specified target dependencies.
- Added the public `CleanupCandidate` domain model, supporting enums, `FileFingerprint`, and `CandidateEvidence`, all with the required `Codable`, `Hashable`, and `Sendable` conformances and explicit public initializers.
- Added `InstalledApplication` and `ApplicationInventory` with explicit public initializers and the required value conformances.
- Added the UI placeholder contract (`MacCleanUI.placeholderName == "Mac Clean"`) and a SwiftUI menu-bar executable rendering `MenuBarExtra("Mac Clean", systemImage: "externaldrive") { Text("Mac Clean") }`.

## TDD Evidence

### RED

Command:

```bash
swift test --filter candidateRetainsSourceEvidenceAndFinderURL
```

Observed expected domain-contract failure after minimal target scaffolding:

```text
error: cannot find 'CleanupCandidate' in scope
error: cannot infer contextual base in reference to member 'applicationCache'
```

The added inventory contract was also run RED before implementation:

```bash
swift test --filter 'candidateRetainsSourceEvidenceAndFinderURL|applicationInventoryRetainsInstalledAndRunningApplications'
```

```text
error: cannot find 'InstalledApplication' in scope
error: cannot find 'ApplicationInventory' in scope
```

The UI contract was run RED before implementation:

```bash
swift test --filter placeholderNameMatchesApplicationName
```

```text
error: module 'MacCleanUI' has no member named 'placeholderName'
```

### GREEN

Focused domain and inventory command:

```bash
swift test --filter 'candidateRetainsSourceEvidenceAndFinderURL|applicationInventoryRetainsInstalledAndRunningApplications'
```

Output: `Test run with 2 tests in 0 suites passed`.

Focused UI command:

```bash
swift test --filter placeholderNameMatchesApplicationName
```

Output: `Test run with 1 test in 0 suites passed`.

Full suite command:

```bash
swift test
```

Output: `Test run with 3 tests in 0 suites passed`; Swift build completed with no Swift compiler warnings.

## Files

- `Package.swift`
- `Sources/CleanCore/Models/CleanupCandidate.swift`
- `Sources/CleanCore/Models/ApplicationInventory.swift`
- `Sources/MacCleanUI/Placeholder.swift`
- `Sources/MacCleanApp/MacCleanApp.swift`
- `Tests/CleanCoreTests/CleanupCandidateTests.swift`
- `Tests/MacCleanUITests/PlaceholderTests.swift`
- `.superpowers/sdd/2026-08-11-mac-clean-foundation-mvp/task-1-report.md`

## Self-Review

- The manifest's products, targets, dependencies, macOS floor, and Swift language mode match the task brief.
- Every requested stored-property model has an explicit public initializer; no cross-target consumer relies on memberwise initialization.
- Candidate evidence, finder source URL, proposed action, installed applications, running bundle IDs, and UI placeholder are covered by real value assertions.
- `git diff --check` reported no whitespace errors.

## Concerns

SwiftPM's executable-target entrypoint conflicts with `@main` in this environment because the generated executable already uses a top-level entrypoint. `MacCleanApp.main()` is called explicitly instead; the executable still renders the exact required `MenuBarExtra`. No functional concern remains.
