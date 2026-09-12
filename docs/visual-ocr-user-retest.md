# Visual OCR real-model retest

After the automated tests pass, verify the configured external vision model with the same Shirohage page used by the translation benchmark.

Expected behavior:

- suspicious local OCR regions may be corrected by visual review without requiring the model to return replacement coordinates;
- a successful visual correction keeps the existing local OCR rectangle and records `ocrSource = visual-review-text`;
- full-page vision recognition returns structured normalized text geometry when the provider supports structured output;
- providers that reject `response_format` continue through the existing fallback path;
- refusal/no-image messages such as “无法返回文本” are not accepted as OCR text.

If every vision call still fails after this change, capture the provider/model name plus the exact API error or raw assistant response. That would point to image-input compatibility or provider transport behavior rather than the old geometry contract.
