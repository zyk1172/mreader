# MangaVision Hard Case Collection

## Purpose

MReader uses the production MangaVision V2B5 five-class detector as shared geometry for
Guided Panel, OCR, translation, and semantic analysis. Random dataset growth is not enough
to improve product behavior: the most valuable failures are pages observed during normal
reading.

The Hard Case collection system records those pages with the detector output that already
exists at the moment of feedback. It is deliberately separate from annotation and model
training.

> Hard Cases are not ground truth until reviewed and annotated.

The collection flow is:

```text
read
  -> notice a recognition problem
  -> mark the current page
  -> save the current V2B5 snapshot and metadata
  -> continue reading
  -> review/export later
  -> annotate outside the reader
  -> consider for a future V3 dataset
```

This feature does not start V3 training and does not automatically turn captured records
into training labels.

## UX

The entry point is developer-only.

In Debug builds, Settings exposes:

```text
Developer / MangaVision
  - Show MangaVision Feedback Shortcut
  - Hard Case Image Retention
  - Hard Cases
```

The shortcut is disabled by default. When enabled it appears in the Reader bottom action
area, away from page-turn and Guided Panel next/previous controls.

- Tap: opens a compact feedback sheet.
- Long press: Quick Mark. It immediately records
  `unspecified_visual_error`, keeps the review state `unreviewed`, gives light haptic
  feedback, and shows `已加入模型训练候选`.
- The existing page long-press gesture remains owned by AI translation. Hard Case capture
  does not replace or compete with that gesture.

The feedback sheet supports multi-select affected areas, issue types, and product impacts,
plus an optional note.

## Schema

The persisted record is `MangaVisionHardCaseRecord`.

It contains:

- record identity and first/last/update timestamps;
- comic and page identity;
- page SHA-256;
- source reference and optional retained-copy reference;
- source pixel dimensions and orientation;
- provider, model identity, model artifact SHA-256, calibration revision, app version/build;
- inference mode;
- preprocessing provenance fields;
- a frozen detection list containing class, score, normalized `xyxy`, and source-pixel
  `xyxy`;
- feedback tags, product impacts, note, count, and review state;
- image-retention policy/failure state.

Export-facing enum values use stable machine-readable names such as
`unspecified_visual_error`, `reading_order`, and `guided_panel`.

The five model classes export as:

| V2B5 domain type | Export class |
| --- | --- |
| panel | frame |
| text | text |
| face | face |
| body | body |
| balloon | balloon |

Training/export identity is obtained from the single code-level
`MangaVisionV2B5ProductionIdentity` source:

- model: `MangaVisionDetectorV2B5`
- Core ML source-tree SHA-256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- calibration: `v2b5-calibration-v1`

The existing `MangaVisionModelManifest` remains the runtime/cache identity source; its
compiled-model hash is intentionally not substituted for the frozen source artifact hash
in exported training metadata. Calibration revision is shared from the production
identity source rather than hardcoded again in Hard Case code.

## Prediction Snapshot

Capture uses `MangaVisionService.cachedAnalysis(...)`.

That API checks only the existing in-memory/disk MangaVision cache. It does **not** call
the provider when the analysis is absent. Therefore feedback never causes a new detector
inference.

When a cached `MangaPageAnalysis` exists, all five classes are copied into the record.
When it does not exist, the record is still valid, with:

```text
analysisState = unavailable
detections = []
```

Page bytes are loaded separately for hashing/retention. Local and archive I/O is performed
off the main actor; remote pages reuse the existing page loader/cache path.

The current runtime does not expose a stable per-page `full / halfLeft / halfRight`
provenance value to consumers. The collector therefore writes `unknown` rather than
inventing provenance. The enum is already versioned for those values when runtime
provenance becomes available.

## Storage

Persistent data lives under:

```text
Application Support/
  MangaVisionHardCases/
    records.json
    images/
```

No large database dependency is introduced.

Image retention supports:

- `referenceOnly`
- `copyOnCapture` (development default)
- `copyOnExport`

Metadata survives image-copy failure and records `imageRetentionFailure`.

## Deduplication

The sample identity is:

```text
pageSHA256 + modelSHA256 + inferenceMode
```

A repeated mark does not duplicate the retained page. It:

- increments `feedbackCount`;
- unions affected areas, issue types, and impacts;
- retains the original `firstSeenAt`;
- advances `lastSeenAt`;
- merges non-empty unique notes.

This makes repeated real-world observations stronger evidence without multiplying image
storage.

## Hard Case Manager

Settings -> Developer / MangaVision -> Hard Cases provides:

- Total / Unreviewed / Reviewed / Annotated / Exported counts;
- storage use;
- filters for all five classes;
- Guided Panel, OCR, and Translation impact filters;
- review-state filters;
- page preview with the frozen V2B5 detection overlay;
- per-class overlay toggles;
- editable issue/impact/note metadata;
- Mark reviewed, Reject, Delete, and Export candidate;
- Delete exported images and Delete all storage actions.

Delete all requires explicit confirmation.

The manager intentionally does not provide a bounding-box ground-truth editor.

## Export

Export is always an explicit user action.

The ZIP structure is:

```text
mangavision-hardcases-YYYYMMDD/
  manifest.json
  records/
    <record-uuid>.json
  images/
    <record-uuid>.<ext>
  predictions/
    <record-uuid>.json
```

Prediction files contain normalized and source-pixel `xyxy` boxes and can be parsed by
ordinary Python/JSON tooling on Windows.

Exported local/custom-scheme source references are reduced to portable file/page
identifiers. They do not require an iOS Application Sandbox absolute path. HTTP/HTTPS
references may remain URLs, while retained images use ZIP-relative paths.

## Privacy

The feature is **LOCAL ONLY** by default.

It does not:

- upload to GitHub;
- upload to a server;
- emit Hard Case telemetry;
- silently export data.

The user must explicitly choose Export Hard Cases or Export candidate.

## Training workflow

A future Mac/Python or Windows workflow may:

1. read the exported ZIP;
2. deduplicate and quality-review candidates;
3. create or correct actual ground-truth annotations;
4. separate hard-case train data from real-world validation data;
5. combine only license-compatible datasets;
6. start a separately reviewed V3 experiment.

The previously observed Manga109-s Final Test set is not imported into Hard Cases by this
feature and must not be silently reused as training data.

## Non-goals and invariants

This implementation does not change:

- V2B5 model weights or artifact;
- confidence thresholds;
- NMS;
- adaptive inference planning or timing;
- OCR recognition policy;
- translation behavior;
- Guided Panel navigation;
- Final Test data.

Hard Case collection observes existing `MangaPageAnalysis` only.
