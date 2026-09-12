# Shirohage Gold Review Sheet

Sample: `manga-page-shirohage-ja`  
Source image: `mreaderTests/Fixtures/sample_shirohage_manga.jpg`  
Pinned SHA-1: `8c828fc750e946ce94038a00782cbe115537c15e`  
License: CC BY-SA 4.0, author しんぎんぐきゃっと  
Current status: **visually corrected candidate / not reportable**

This sheet is the human handoff for the first full-page manga benchmark. The original machine-generated candidate has now been corrected against the user-provided numbered review image: false-positive face/newspaper regions were removed and fragmented OCR was rebuilt into complete vertical text columns. The result is still intentionally not benchmark truth until a person gives final confirmation against the pinned source image.

## Review overlay

`docs/shirohage-gold-review-overlay.png` has been regenerated from the corrected Gold candidate. Its labels `1` through `10` map directly to the corrected regions in the table below. The original user-provided screenshot remains the review evidence used to identify the machine candidate's false positives, fragmentation and missed middle column.

The user-provided screenshot established the following corrections:

- old regions 3 and 4: delete as face/art false positives;
- old regions 5 and 6: delete as newspaper/art false positives;
- old region 1: do not keep as an isolated one-character fragment; rebuild the full right narration block;
- old region 9: do not keep as an isolated sentence tail; rebuild the full lower-left narration block;
- old regions 7 and 8: retain as evidence for the left-top speech balloon, while adding its previously missed middle column.

## Corrected candidate regions

Reading order follows Japanese vertical layout: rightmost column first within each text block, then move leftward.

| # | Region | Corrected source text | Reading order | Bubble ID |
| ---: | --- | --- | ---: | --- |
| 1 | `region-001` | `「有名人」の基準は、` | 0 | none |
| 2 | `region-002` | `「ウィキペディアに記事` | 1 | none |
| 3 | `region-003` | `があるか」です。` | 2 | none |
| 4 | `region-004` | `ウィキペディアに` | 3 | `bubble-left-top` |
| 5 | `region-005` | `のってたら` | 4 | `bubble-left-top` |
| 6 | `region-006` | `有名人です。` | 5 | `bubble-left-top` |
| 7 | `region-007` | `ウィキペディアにのって` | 6 | none |
| 8 | `region-008` | `ないのに有名人のよう` | 7 | none |
| 9 | `region-009` | `にふるまうのは自惚れ` | 8 | none |
| 10 | `region-010` | `です。` | 9 | none |

The three left-top columns share one physical speech-balloon ID. The right and lower-left rectangular narration boxes intentionally have no `bubbleID`; the benchmark must not fabricate speech balloons for rectangular text panels. Newspaper scribbles and face marks are excluded because they are not stable translatable Japanese text.

## Current reconstructed text

The corrected regions reconstruct these three visible text blocks:

- Right narration: `「有名人」の基準は、「ウィキペディアに記事があるか」です。`
- Left-top speech balloon: `ウィキペディアにのってたら有名人です。`
- Lower-left narration: `ウィキペディアにのってないのに有名人のようにふるまうのは自惚れです。`

## Final human approval checklist

- [x] Machine false-positive face/newspaper regions removed from the corrected candidate.
- [x] Fragmented candidate text rebuilt into complete visible vertical columns.
- [x] Reading order is contiguous from `0` and follows the visible vertical text layout.
- [x] The left-top physical speech balloon uses one shared `bubbleID`; narration boxes remain independent.
- [ ] A human reviewer has checked every corrected transcription character against the pinned source image.
- [ ] A human reviewer has checked every corrected rectangle against the pinned source image.
- [ ] `expectedPageState` has been explicitly changed from `unknown` to the reviewed state.
- [ ] `review` records the human reviewer, ISO-8601 review time, `visualHumanReview`, and the pinned source-image SHA-1 above.
- [ ] `verificationStatus` has been changed to `humanVerified` only after final confirmation.
- [ ] `translation_quality_manifest.json` changes this sample from `pending` to `ready` only after the annotation is reportable.

## Reportable gate

The test code rejects page-level scoring unless all of the following are true:

1. the annotation is structurally valid;
2. the page state is resolved;
3. `verificationStatus == humanVerified`;
4. a valid human review receipt is present and bound to the pinned source image.

Until the final human confirmation is recorded, this corrected candidate can be used for review and diagnostics but cannot produce official detection recall, CER, reading-order, or grouping claims.
