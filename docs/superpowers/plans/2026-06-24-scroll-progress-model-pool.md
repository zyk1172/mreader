# Scroll Progress And AI Model Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make scrolling readers report and persist the real visible page, and add sequential AI model-pool failover with daily rate-limit reset.

**Architecture:** `ContinuousScrollReader` will collect each rendered page's real frame in a named coordinate space and delegate pure visible-page selection to a testable helper. `AIModelPoolManager` will own persisted pool configuration, round-robin position, per-model daily rate-limit state, and sequential failover while existing translator request payloads remain unchanged.

**Tech Stack:** SwiftUI, Swift Concurrency actors, Swift Testing, UserDefaults, URLSession.

---

### Task 1: Visible Page Selection

**Files:**
- Modify: `mreader/ReaderView.swift`
- Test: `mreaderTests/mreaderTests.swift`

- [ ] Add failing tests for visible-area selection, center-distance tie breaking, and empty frame input.
- [ ] Run the tests and confirm the helper is missing.
- [ ] Add a pure `ReaderVisiblePageDetector` helper.
- [ ] Add a named scroll coordinate space and a page-frame `PreferenceKey`.
- [ ] Update `ContinuousScrollReader` to consume real frames and write through its `currentPageIndex` binding.
- [ ] Preserve the existing 0.7-second progress persistence throttle and forced background/disappear writes.

### Task 2: AI Model Pool

**Files:**
- Create: `mreader/AIModelPoolManager.swift`
- Modify: `mreader/AITranslator.swift`
- Modify: `mreader/ReaderView.swift`
- Modify: `mreader/ContentView.swift`
- Test: `mreaderTests/mreaderTests.swift`

- [ ] Add failing tests for model normalization, round-robin order, rate-limit classification, failover, default fallback, and next-day reset.
- [ ] Implement persisted pool state in an actor.
- [ ] Route OCR and vision translation requests through sequential model selection.
- [ ] Keep API key, base URL, prompt templates, and request body format unchanged.
- [ ] Add model-pool editor, status rows, and manual reset to settings.
- [ ] Include pool configuration in settings backup and restore.

### Task 3: Verification

**Files:**
- Verify all changed files.

- [ ] Run Swift tests.
- [ ] Run `swiftc -parse` and `git diff --check`.
- [ ] Build in Xcode and remove project-source warnings.
