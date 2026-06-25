# MReader Icon Composer App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved B2-B silver-glass MReader icon as an editable Icon Composer document, connect it to the app target, and verify it on the connected iPhone.

**Architecture:** Create four source-controlled SVG layers with a common 1024-point canvas, import them into one Icon Composer document, and retain the existing PNG only as a rollback reference. Xcode will compile the `.icon` document as the app icon while the project continues to use the existing `AppIcon` asset name.

**Tech Stack:** SVG, Apple Icon Composer, Xcode 27, Swift asset catalogs, `xcodebuild`

---

### Task 1: Create the icon layer artwork

**Files:**
- Create: `mreader/IconAssets/MReaderIcon/background.svg`
- Create: `mreader/IconAssets/MReaderIcon/book-frame.svg`
- Create: `mreader/IconAssets/MReaderIcon/m-pages.svg`
- Create: `mreader/IconAssets/MReaderIcon/sparkle.svg`

- [ ] **Step 1: Create a 1024 x 1024 silver glass background**

Use a full-canvas silver-blue rectangle with a restrained upper-left highlight. Do not draw an app-icon corner mask.

- [ ] **Step 2: Create the balanced dark book frame**

Place the rounded frame inside the 18% safe margin and use a dark charcoal fill with enough optical weight to remain visible at 29 points.

- [ ] **Step 3: Create the M-shaped page layer**

Draw two open-book page polygons meeting at the center, with cyan-blue on the left and violet on the right.

- [ ] **Step 4: Create the sparkle layer**

Draw one four-point sparkle in the upper-right quadrant, smaller than one-quarter of the book width.

- [ ] **Step 5: Render a composite preview**

Run:

```bash
qlmanage -t -s 1024 -o /tmp/mreader-icon-preview mreader/IconAssets/MReaderIcon/*.svg
```

Expected: all four SVG files render without parse errors.

### Task 2: Build the Icon Composer document

**Files:**
- Create: `mreader/MReader.icon`

- [ ] **Step 1: Open Icon Composer from Xcode 27**

Run:

```bash
open -a "/Users/zhengyunkai/Downloads/Xcode-beta.app/Contents/Applications/Icon Composer.app"
```

- [ ] **Step 2: Create and save the document**

Create a new icon document and save it as `mreader/MReader.icon`.

- [ ] **Step 3: Import the four layers in back-to-front order**

Order:

1. `background.svg`
2. `book-frame.svg`
3. `m-pages.svg`
4. `sparkle.svg`

- [ ] **Step 4: Configure layer depth and glass**

Keep the background flat, raise the frame slightly, raise the M pages above the frame, and place the sparkle at the highest depth. Use restrained specular highlights so small previews do not lose contrast.

- [ ] **Step 5: Verify appearances**

Inspect default, dark, and tinted/monochrome previews. The book and M silhouettes must remain distinct without relying on the color gradient.

### Task 3: Connect the icon to the Xcode target

**Files:**
- Modify: `mreader.xcodeproj/project.pbxproj`
- Preserve: `mreader/Assets.xcassets/AppIcon.appiconset/AppIcon.png`

- [ ] **Step 1: Add `MReader.icon` to the app target**

Use Xcode's file synchronization or project editor so the icon document is included in the `mreader` target without adding unrelated files.

- [ ] **Step 2: Keep the app icon build setting consistent**

Ensure `ASSETCATALOG_COMPILER_APPICON_NAME` resolves to the composed icon's name and does not create a duplicate icon warning.

- [ ] **Step 3: Inspect the project diff**

Run:

```bash
git diff --check
git diff -- mreader.xcodeproj/project.pbxproj
```

Expected: no whitespace errors and only icon-related project changes.

### Task 4: Build and visually verify

**Files:**
- Test: `mreader.xcodeproj`

- [ ] **Step 1: Build for the connected device**

Run:

```bash
DEVELOPER_DIR=/Users/zhengyunkai/Downloads/Xcode-beta.app/Contents/Developer \
xcrun xcodebuild \
  -project mreader.xcodeproj \
  -scheme mreader \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-000A6D6A2143801C' \
  -allowProvisioningUpdates \
  build
```

Expected: `** BUILD SUCCEEDED **` with no app-icon compiler error.

- [ ] **Step 2: Inspect compiled icon warnings**

Search the build output for `AppIcon`, `icon`, `warning`, and `error`. Any warning caused by the new icon must be fixed before completion.

- [ ] **Step 3: Inspect on device**

Install/run the Debug build on `郑云凯` and verify the icon at Home Screen size, Settings size, default appearance, and dark appearance.

- [ ] **Step 4: Final repository check**

Run:

```bash
git status --short
git diff --check
```

Expected: the new icon sources/document and only intended icon project changes are present.
