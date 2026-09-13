# Visual OCR reliability

This change separates two jobs that previously shared one overly strict response contract.

## Region review

When local OCR has already located a suspicious text region, the vision model is now asked only to transcribe the cropped region and return a confidence value. The local OCR geometry, bubble geometry, layout-safe region, orientation and role remain authoritative for that review pass.

A region review therefore no longer fails merely because a model omitted or reformatted `textBox`/`bubbleBox` coordinates.

The parser accepts the preferred coordinate-free JSON response and a plain-text fallback, while rejecting common refusal/no-image messages instead of storing them as OCR text.

## Full-page vision recognition

Full-page recognition still needs normalized geometry. Its system prompt and user contract now agree on `layoutSafeRegion`, and capable transports receive a dedicated recognition JSON Schema rather than only a generic JSON-object request. Existing fallback behavior remains available for providers that reject structured response formats.

The prompt and strict schema now use the same optional-geometry representation: every item includes the geometry keys; `bubbleBox` / `layoutSafeRegion` use `null` when unavailable, while `textPolygon` / `bubblePolygon` use empty arrays when they cannot be determined reliably. This avoids telling the model to omit fields that structured output simultaneously requires.

## Vision connection probe

The settings-page vision test now proves image ingestion instead of only proving HTTP connectivity. It renders a random six-character challenge code into an image, keeps the code out of the text prompt, and only reports success when the model reads the same code back. A text-only model that ignores the image can no longer pass by replying `OK`.

A successful probe also upgrades an `unknown` model descriptor to `supportsVision = true` in the current editor state. A failed probe does not automatically mark the model unsupported because provider outages and temporary model failures can produce false negatives.

## Validation boundary

Unit/CI coverage can verify parsing, geometry preservation, request-contract behavior and the challenge-response verifier. It still cannot prove that a specific external provider/model works until the user runs the visual connection probe and then retests a real manga page in the app.