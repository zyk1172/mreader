# Visual OCR reliability

This change separates two jobs that previously shared one overly strict response contract.

## Region review

When local OCR has already located a suspicious text region, the vision model is now asked only to transcribe the cropped region and return a confidence value. The local OCR geometry, bubble geometry, layout-safe region, orientation and role remain authoritative for that review pass.

A region review therefore no longer fails merely because a model omitted or reformatted `textBox`/`bubbleBox` coordinates.

The parser accepts the preferred coordinate-free JSON response and a plain-text fallback, while rejecting common refusal/no-image messages instead of storing them as OCR text.

## Full-page vision recognition

Full-page recognition still needs normalized geometry. Its system prompt and user contract now agree on `layoutSafeRegion`, and capable transports receive a dedicated recognition JSON Schema rather than only a generic JSON-object request. Existing fallback behavior remains available for providers that reject structured response formats.

## Validation boundary

Unit/CI coverage can verify parsing, geometry preservation and request-contract behavior, but it cannot prove that a specific external provider/model actually receives or understands image input. After merge, the real configured vision model must be retested in the app.
