# Shelf Large Card Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore large, aligned comic and series cards on iPhone by deriving the two-column grid from the full shelf container width, with approximately four cards visible in the primary viewport.

**Architecture:** Keep the existing card views and shared sizing metrics. Replace the self-referential inner-content width preference with an outer `GeometryReader`, then use one deterministic `ShelfCardMetrics` result for root comics, series, and series-detail grids.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Xcode iOS simulator screenshots.

## Global Constraints

- iPhone uses exactly two equal-width columns.
- Comic and series cards keep identical cover, title, progress, metadata, and total heights.
- Series cover stacking stays clipped inside the fixed cover frame.
- iPad and Mac retain adaptive multi-column behavior.
- Do not change shelf sorting, selection, context menus, navigation, or source filtering.
- Preserve user-authored uncommitted changes in the working tree.

---

### Task 1: Full-Width Shelf Metrics

**Files:**
- Modify: `mreader/ContentView.swift:1017-1070`
- Modify: `mreader/ContentView.swift:2126-2160`
- Test: `mreaderTests/mreaderTests.swift`

**Interfaces:**
- Produces testable internal `ShelfCardMetrics.cardWidth(for:)` and `gridLayout(for:idiom:)`.
- Consumed by the root shelf and series-detail grids.

- [ ] **Step 1: Write failing iPhone and iPad metric tests**

```swift
@Test func iPhoneShelfUsesTwoFullWidthColumns() {
    let result = ShelfCardMetrics.gridLayout(for: 393, idiom: .phone)
    #expect(result.columns.count == 2)
    #expect(result.cardWidth == 170)
}

@Test func iPadShelfUsesAdditionalColumns() {
    let result = ShelfCardMetrics.gridLayout(for: 744, idiom: .pad)
    #expect(result.columns.count >= 3)
    #expect(result.cardWidth >= 160)
}
```

- [ ] **Step 2: Run tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test \
  -project mreader.xcodeproj -scheme mreader \
  -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7' \
  -only-testing:mreaderTests
```

Expected: FAIL because `ShelfCardMetrics` is private and does not accept an explicit idiom.

- [ ] **Step 3: Make metrics deterministic**

Change `ShelfCardMetrics` from private to internal and add an explicit idiom parameter with the production default:

```swift
static func gridLayout(
    for containerWidth: CGFloat,
    idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
) -> (columns: [GridItem], cardWidth: CGFloat)
```

For iPhone, calculate:

```swift
floor((containerWidth - horizontalPadding * 2 - columnSpacing) / 2)
```

Only guard invalid widths before layout. Do not let the initial `132pt` fallback become the measured content width.

- [ ] **Step 4: Replace the inner width preference**

Remove `libraryPageWidth` and `LibraryWidthKey`. Wrap the shelf page content in an outer `GeometryReader`, obtain `geometry.size.width`, and derive `gridLayout` from that full width. Keep the scroll view and refresh behavior unchanged.

```swift
private var libraryPage: some View {
    GeometryReader { geometry in
        let gridLayout = ShelfCardMetrics.gridLayout(for: geometry.size.width)
        ScrollView {
            shelfContent(gridLayout: gridLayout)
        }
        .refreshable { await refreshShelfLibraries() }
    }
}
```

The helper may be a `@ViewBuilder` function, but it must receive the resolved layout instead of reading mutable width state.

- [ ] **Step 5: Verify shared card geometry**

Confirm both `comicGridItem` and `seriesGridItem` use `ShelfCardMetrics.cardHeight(for:)`, and both `ComicCoverCard` and `SeriesCard` use the same `coverHeight`, `titleHeight`, `progressHeight`, and `metaHeight`. Keep stack offsets inside the cover frame and `.allowsHitTesting(false)` on decorative covers.

- [ ] **Step 6: Run tests and verify GREEN**

Run the Task 1 command. Expected: shelf metric and existing tests PASS.

- [ ] **Step 7: Commit**

```bash
git add mreader/ContentView.swift mreaderTests/mreaderTests.swift
git commit -m "fix: restore full-width shelf cards"
```

### Task 2: iPhone and iPad Visual Verification

**Files:**
- Modify only if visual verification exposes a shelf-scoped defect.

**Interfaces:**
- Verifies Task 1 without changing shelf behavior.

- [ ] **Step 1: Build for iPhone 17**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild build \
  -project mreader.xcodeproj -scheme mreader \
  -destination 'platform=iOS Simulator,id=36299868-0969-4FDF-8CB8-4761F8D4C4A7'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Launch and capture the iPhone shelf**

Boot iPhone 17 simulator `36299868-0969-4FDF-8CB8-4761F8D4C4A7`, install the built app, open the shelf, and capture a screenshot. Verify two equal columns, covers using the full content width, identical comic and series alignment, clipped stacks, and approximately two visible rows.

- [ ] **Step 3: Build and launch on iPad mini**

Use simulator `719E1C0B-CC86-48AC-955A-786552060096`. Verify at least three adaptive columns and no forced phone-sized two-column grid.

- [ ] **Step 4: Check hit areas and list mode**

Tap the left and right edges of adjacent cards to ensure no overlap. Long-press comic and series cards to confirm menus remain available. Switch to list mode and verify row sizing is unchanged.

- [ ] **Step 5: Final verification**

Run the Task 1 test command and `git diff --check`. Expected: `** TEST SUCCEEDED **` and no whitespace errors.
