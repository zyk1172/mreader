# Manga Vision V2B5 Legacy Fallback Archive

This is the last mReader production state that retains the legacy `PanelDetector`
fallback alongside the V2B5 production detector.

## Archive identity

- Archive tag: `v2b5-fallback-archive`
- Archive commit: the commit targeted by the annotated archive tag; the full SHA is recorded by the tag and final closeout record.
- Production provider: V2B5 (`MangaVisionV2B5Provider`)
- Fallback provider: OLD (`YOLOMangaVisionProvider` / `PanelDetector`)
- Active model classes: `frame`, `text`, `face`, `body`, `balloon`
- Core ML tree SHA256: `ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5`
- Calibration revision: `v2b5-calibration-v1`
- Rollback documentation: [`V2B5_ROLLBACK.md`](V2B5_ROLLBACK.md)

The archive preserves the V2B5 production provider, the OLD runtime fallback,
the `PanelDetector` model resource, and the rollback documentation as one
recoverable Git state. Future five-class development must branch from this
archive and must not silently re-embed OLD into the active app.

## Public release safety

The repository is public. The repository source is GPLv3, and the existing
model record identifies the upstream model repository as MIT while noting that
dataset and Ultralytics terms require independent review. Permission to
redistribute the compiled `PanelDetector` artifact as a public release asset
has not been verified.

Therefore no GitHub Release or separate legacy-model binary asset is created
for this archive:

`RELEASE_BINARY_PUBLICATION_SKIPPED_FOR_LICENSE_SAFETY`

The Git tag and its commit remain the recovery record. The existing attribution
and license records are preserved unchanged.
