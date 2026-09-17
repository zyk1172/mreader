# OCR ROI Coverage Guard

Manga Vision text regions are a performance hint, not the authority for OCR recall.

The OCR pipeline uses three recovery levels:

1. `roiOnly`: detector ROIs cover the cheap full-page locator evidence; no additional accurate OCR is run.
2. `partialRescan`: one or a few locator blocks are outside detector coverage; only small padded missing regions are rescanned and mapped back to whole-page coordinates.
3. `fullPage`: detector coverage is substantially incomplete or page-level character evidence shows a severe deficit; OCR falls back to the existing full-page pipeline.

The coverage probe uses low-resolution Apple Vision `.fast` recognition without language correction. Its recognized text is never sent directly to translation. It contributes only geometry and coarse character-count evidence used to select the recovery level.

This keeps healthy detector-assisted pages fast while preventing a Manga Vision false negative from becoming an OCR false negative.
