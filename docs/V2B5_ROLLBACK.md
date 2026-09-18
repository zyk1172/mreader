# Manga Vision V2B5 Rollback

## Current production

- Production provider: V2B5 (`MangaVisionV2B5Provider`)
- Fallback provider: OLD (`YOLOMangaVisionProvider` / `PanelDetector`)
- Core ML precision: Full FP32
- OLD retention: keep OLD for at least one formal release cycle after the V2B5 release.

## Rollback triggers

A rollback may be initiated for:

- V2B5 model load failure.
- Severe production crash.
- Severe Reader regression.
- Severe device compatibility issue.

## Rollback action

Switch only the production provider default from V2B5 to OLD. Keep the V2B5 artifact and all provider/debug routing available so the change remains reversible.

## Explicitly unchanged

Rollback must not:

- delete user data;
- modify calibration;
- change the database;
- modify or replace the V2B5 artifact;
- delete OLD, `PanelDetector`, or the V2B5 provider.

After a rollback, verify that the OLD provider and `PanelDetector` resource are bundled and that the normal Reader path is functional. Any future V2B5 re-adoption requires a separate reviewed change.
