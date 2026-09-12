# Shirohage Gold Review Sheet

Sample: `manga-page-shirohage-ja`  
Source image: `mreaderTests/Fixtures/sample_shirohage_manga.jpg`  
Pinned SHA-1: `8c828fc750e946ce94038a00782cbe115537c15e`  
License: CC BY-SA 4.0, author しんぎんぐきゃっと  
Current status: **candidate / not reportable**

This sheet is the human handoff for the first full-page manga benchmark. The machine-generated candidate is intentionally not benchmark truth. A reviewer must inspect the original image, correct every text region, confirm reading order and bubble grouping, resolve the page state, and only then add the review receipt and promote the manifest entry to `ready`.

## Review overlay

The generated overlay is stored at `docs/shirohage-gold-review-overlay.png`. Each numbered box corresponds to the candidate region below. The overlay is for review only; it is not a source of truth.

## Candidate regions

| # | Region | Current OCR candidate | Reading order | Bubble ID |
| ---: | --- | --- | ---: | --- |
| 1 | `region-001` | `は` | 0 | none |
| 2 | `region-002` | `があるか」です。` | 1 | none |
| 3 | `region-003` | `い` | 2 | none |
| 4 | `region-004` | `い` | 3 | none |
| 5 | `region-005` | `ハト` | 4 | none |
| 6 | `region-006` | `OEIIII` | 5 | none |
| 7 | `region-007` | `、ウッキペディアに` | 6 | none |
| 8 | `region-008` | `有名人です。` | 7 | none |
| 9 | `region-009` | `です。` | 8 | none |

The strings above are pipeline output, not verified transcription. In particular, Latin-looking `OEIIII`, isolated one-character regions, and punctuation/wording must be checked against the source image rather than accepted because OCR produced them.

## Human approval checklist

- [ ] Every visible translatable Japanese text region is represented exactly once.
- [ ] False-positive OCR regions are removed.
- [ ] Region rectangles match the intended text, not nearby art or another balloon.
- [ ] Japanese transcription is corrected character-by-character.
- [ ] Reading order is contiguous from `0` and matches intended manga reading order.
- [ ] Lines belonging to the same physical speech balloon share one non-empty `bubbleID`; narration/SFX without a physical balloon remain independent.
- [ ] `expectedPageState` is explicitly changed from `unknown` to the reviewed state.
- [ ] Reference translations are added only when they have been reviewed; multiple natural translations may be handled by later human-review scoring rather than forced exact-match equivalence.
- [ ] `review` records the human reviewer, ISO-8601 review time, `visualHumanReview`, and the pinned source-image SHA-1 above.
- [ ] `verificationStatus` is changed to `humanVerified` only after all checks are complete.
- [ ] `translation_quality_manifest.json` changes this sample from `pending` to `ready` only after the annotation is reportable.

## Reportable gate

The test code rejects page-level scoring unless all of the following are true:

1. the annotation is structurally valid;
2. the page state is resolved;
3. `verificationStatus == humanVerified`;
4. a valid human review receipt is present.

Until then, OCR output can be used for diagnostics and candidate preparation but cannot produce official detection recall, CER, reading-order, or grouping claims.
