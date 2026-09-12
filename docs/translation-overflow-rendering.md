# Translation overflow rendering

When a translated block cannot fit at the configured minimum readable font size, mReader must not replace the translation with an icon-only surface or expand an assist card across a large portion of the artwork.

The reader now treats `.needsExpansion` as an interaction state rather than a large-layout state:

- keep a readable, clipped translation preview visible;
- anchor the preview to the source text region;
- cap horizontal previews at 120×56 points and vertical previews at 56×120 points;
- use a lighter overflow surface than the normal assist overlay;
- open the full canonical translation only when that specific preview is tapped;
- keep normal `.fitted` rendering unchanged.

This policy does not change manga semantic reading order, OCR segmentation, translation content, or model request scheduling.
