# MReader Full Code Review Design

Date: 2026-06-24

## Purpose

Run a full code review of the current MReader codebase and working tree, focused on bugs, incomplete feature wiring, repeated logic, warnings, and code paths that have repeatedly failed user acceptance. This review must not change application code. Its output is a prioritized issue report plus a staged repair plan that can be approved before implementation.

The review target is the current working tree, including uncommitted changes. The repository already contains substantial modifications in `ContentView.swift`, `ReaderView.swift`, `ComicLibraryStore.swift`, Komga integration files, OCR/AI translation files, and remote page cache files. The review must treat those changes as active product code rather than ignoring them.

## Scope

The review will use a combined A+C+B method:

1. A: call-chain-first review.
2. C: build, warning, runtime-warning, and stability review.
3. B: file-by-file fallback review.

The review is intentionally broad, but the first pass prioritizes the features the user has repeatedly reported as incomplete or regressing:

- Bookshelf refresh and Komga disappearance after repeated pull-to-refresh.
- Local library and Komga coexistence.
- Komga sync, source enable/disable, deletion, stale cleanup, page loading, cover loading, and reading progress.
- Reader gestures: single tap, double tap, long press, toolbar, settings sheet, horizontal/vertical/double-page/scroll modes.
- Scroll mode current page detection and reading progress persistence.
- OCR magnification, OCR text translation, vision translation, prompts, JSON parsing, coordinate overlay, and filtering.
- Local library scanning, Files bookmark permissions, archive formats, folder chapters, PDF/EPUB, thumbnail rebuild, delete/open/share behavior.
- Reading statistics, date ranges, daily goal UI, and state persistence.
- Cache behavior: local image cache, remote page cache, prefetch, memory/disk limits, stale remote pages.
- Web upload server and temporary files.
- Haptics and settings backup/restore.

## Non-Goals

This review will not:

- Implement fixes before the user approves a repair plan.
- Redesign the UI visually.
- Reintroduce SMB or WebDAV.
- Replace Komga with another provider.
- Commit application code changes.
- Remove existing features merely because their implementation is messy.

## Review Method

### A. Call-Chain-First Review

For each high-risk feature, trace from user action to persistence and back to UI:

1. UI entry point.
2. View state and bindings.
3. Store or manager method.
4. Service/provider/client.
5. Cache or disk persistence.
6. Merge/filter/sort logic.
7. UI refresh and recovery path.

Each call-chain finding must answer:

- What user-visible behavior can fail?
- Which file and function are involved?
- What state is changed?
- Is another path overwriting or filtering that state?
- Was the new logic written but not connected to an active entry point?
- Does a refresh, rescan, reload, or app restart preserve the expected behavior?

Primary call chains:

- `ContentView` pull-to-refresh/menu refresh -> `ComicLibraryStore.syncAllLibrariesAsync()` -> local scan and Komga sync -> `visibleComics`.
- Komga settings -> `KomgaProvider` -> `KomgaAPIClient` -> `ComicBook` conversion -> bookshelf display -> reader loading.
- Reader open -> `ReaderContainerView` -> local or remote page load -> `ReaderView` -> progress save -> `ComicLibraryStore.update(_:)` -> optional Komga progress update.
- Scroll reader -> scroll offset/current page calculation -> progress persistence -> restore on next open.
- AI button/long press/auto translate -> OCR or vision mode -> request prompt -> response parse -> overlay layout.
- Local library root/import/scan/delete/open/share -> `ComicManager` -> security-scoped resource and user-visible Files path.

### C. Build, Warning, and Stability Review

Run the strongest available checks without changing code:

- `git diff --check`.
- Swift parse/type checks where possible.
- `xcodebuild` if the environment permits package resolution.
- Search for SwiftUI runtime warning patterns, deprecated APIs, force unwraps, force casts, unchecked concurrency, synchronous main-thread IO, and oversized memory operations.

Classify warnings as:

- Project-code warning: must be fixed or explicitly accepted.
- Tooling/environment warning: document only, such as sandboxed `xcodebuild` package resolution failures or simulator service issues.

Also inspect likely stability risks:

- Main actor disk IO.
- Large file uploads and archive decoding.
- Remote page prefetch cancellation.
- Image decoding size and cache cost.
- Security-scoped resource lifecycle.
- SwiftUI gesture recognizers attached to window-level views.

### B. File-by-File Fallback Review

After call-chain and warning review, scan each major file for local defects, duplication, and unused code:

- `ContentView.swift`: bookshelf, tabs, settings, import, statistics, backup/restore.
- `ReaderView.swift`: reader modes, gestures, toolbar, scroll reader, OCR/AI overlay, page loading hooks.
- `ComicLibraryStore.swift`: merge/update logic, progress, sync, delete, thumbnail tasks.
- `ComicManager.swift`: local scan, archive parsing, PDF/EPUB support, bookmarks, temp files.
- `KomgaProvider.swift`, `KomgaAPIClient.swift`, `KomgaModels.swift`: sync, API paths, decoding, keychain, progress, delete.
- `RemotePageLoader.swift`: remote cache, prefetch, 404 behavior, memory/disk limits.
- `AITranslator.swift`, `OCRPreprocessor.swift`: OCR accuracy, filtering, prompt wiring, vision JSON and coordinates.
- `LocalWebServer.swift`: upload parsing, temp cleanup, memory pressure.
- `HapticManager.swift`: global switch and call consistency.
- Test files: coverage gaps and missing regression tests.

## Finding Format

Each issue must be reported with this structure:

- Severity: `P0`, `P1`, `P2`, or `P3`.
- Title.
- Files and key functions.
- User-visible symptom.
- Call chain.
- Root cause.
- Why previous changes did not fully fix it, when applicable.
- Recommended fix.
- Risk of breaking existing behavior.
- Manual test steps.
- Suggested automated test, when practical.

Severity definitions:

- `P0`: build failure, crash, data loss, deleted user files incorrectly, or core app unusable.
- `P1`: major user-visible feature failure or repeated regression.
- `P2`: performance issue, runtime warning, duplicate state, fragile architecture, missing error handling.
- `P3`: dead code, naming, cleanup, small maintainability improvement.

## Repair Plan Output

The final report must include a staged repair plan:

1. Fix P0/P1 bugs with minimal code movement.
2. Add or update focused regression tests where practical.
3. Fix project-code warnings and runtime-warning causes.
4. Remove clearly dead or disconnected code.
5. Only then propose larger refactors, such as splitting `ContentView.swift` and `ReaderView.swift`.

Each stage must list:

- Files to touch.
- Expected behavior change.
- Regression risk.
- Manual acceptance checklist.
- Whether the work should be committed separately.

## Acceptance Criteria

The review is complete when it produces:

- A prioritized issue list grounded in code paths and file locations.
- A specific explanation for repeated user-reported failures.
- A separation between real code issues and environment/tooling warnings.
- A staged repair plan that protects existing local library, Komga, OCR/AI, reader, and statistics functionality.
- A list of code paths that should not be changed during early bug fixes because they are currently working or high risk.

## Constraints

- Do not modify app code during the review.
- Do not revert user or prior worktree changes.
- Do not rely on assumptions when a code path can be traced.
- Prefer `rg` and direct file reads.
- If `xcodebuild` cannot run because of sandbox/package issues, document the exact failure and continue with static analysis.
- Keep recommendations scoped to MReader’s current SwiftUI architecture.

