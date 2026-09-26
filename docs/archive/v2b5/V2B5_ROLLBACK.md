# Manga Vision V2B5 Rollback

## Active production

- Production provider: V2B5 (`MangaVisionV2B5Provider`)
- Active model resource: `MangaVisionV2B5.mlmodelc`
- Core ML precision: Full FP32
- Active runtime fallback: none
- Active OLD/COMPARE modes: removed from the app

The geometric `VisionRectanglePanelDetector` safety path used by
`PanelDetectionService` is not a legacy model provider. It does not load or
route to `PanelDetector` and remains a non-model reader-resilience fallback.

## Rollback triggers

A rollback may be initiated for:

- V2B5 model load failure.
- Severe production crash.
- Severe Reader regression.
- Severe device compatibility issue.

## Rollback action

Rollback is a Git/Release operation, not an active runtime provider switch:

1. Stop the affected release rollout.
2. Check out the historical `v2b5-fallback-archive` tag or its corresponding
   release commit `c8b5c04300aea0d53325c7f4e1794e52c1e87499`.
3. Build and release that archived snapshot through the normal reviewed
   release process.

The archive tag is the last mReader state containing V2B5 together with the
legacy OLD `PanelDetector` fallback. New five-class development must not
re-embed OLD into the active branch merely to implement rollback.

## Explicitly unchanged during rollback preparation

Rollback preparation must not:

- delete user data;
- modify calibration;
- change the database;
- modify or replace the V2B5 artifact;
- reintroduce OLD into the active development branch;
- rerun the sealed Manga109-s Final Test.

The archive documentation and annotated tag preserve the complete historical
fallback implementation. Any future production rollback is a separate,
reviewed Git/Release action.
