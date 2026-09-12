# Visual OCR validation boundary

The repository tests validate request construction, response parsing and geometry preservation. They do not call a paid external vision model in CI.

A green CI result therefore means the app-side visual OCR contract is internally consistent; it does not guarantee that every configured provider/model accepts image input. Real-provider verification remains required after merge.
