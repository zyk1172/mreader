# First real manga page benchmark

This benchmark exercises mReader's **actual local OCR/structure pipeline** on the licensed fixture `mreaderTests/Fixtures/sample_shirohage_manga.jpg`.

It is intentionally split into two kinds of evidence:

- `sample_shirohage_manga.baseline.json`: observed output from `MangaOCRPipeline` on a specific OS/Xcode/Vision runtime.
- `sample_shirohage_manga.gold.json`: a machine-assisted annotation **candidate**. It is not quality ground truth until a person checks every region and changes `verificationStatus` from `candidate` to `humanVerified`.

Do not compare a candidate annotation against the same OCR run and report that result as accuracy. That would make the system grade itself.

## Integrity rules

- Machine-generated page annotations always start with `expectedPageState: unknown`. OCR output may suggest that text exists or does not exist, but it cannot establish benchmark truth about `completed`, `partial`, `noText` or `failed`.
- A page becomes reportable gold only after a human reviewer resolves the page state, verifies the regions/order/grouping, sets `verificationStatus` to `humanVerified`, and the manifest entry is `ready`.
- `bubbleBlockCount` is the number of grouped output blocks produced by the pipeline. It is not a count of physical speech balloons.
- `physicalBubbleCount` counts unique non-nil detected bubble rectangles carried by those blocks. A value of `0` is valid even when `bubbleBlockCount` is nonzero.
- Baseline schema v2 records capture provenance so results from different Xcode/Vision/runtime environments are not silently compared as if they were equivalent.

The pinned Shirohage baseline was captured on GitHub Actions from commit `4675a607c2b7835671631c27475e8a911b914d7b`, workflow run `34705735085`, using Xcode 26.5 (`17F66`), `iphonesimulator26.5`, iPhone 17 on iOS 26.5. Its OCR text, geometry, confidence and latency remain an observed diagnostic snapshot, not quality ground truth.

## Run the baseline in Xcode

1. Open `mreader.xcodeproj` and select the `mreader` scheme.
2. Edit Scheme → Test → Arguments → Environment Variables.
3. Add `MREADER_RUN_PAGE_BENCHMARK` with value `1`.
4. In the Test navigator, run only:
   `TranslationFirstPageBaselineTests/testGenerateShirohagePageBaselineWhenOptedIn`.
5. Open the test result attachments:
   - `sample_shirohage_manga.baseline.json`
   - `sample_shirohage_manga.gold.candidate.json`

Without the environment variable the real-page test is skipped, so ordinary CI stays deterministic.

## Run from Terminal

The following uses the same simulator family as CI. If your installed Xcode/runtime differs, change `DESTINATION` accordingly.

```bash
export MREADER_RUN_PAGE_BENCHMARK=1
export DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=26.5'

xcodebuild \
  -project mreader.xcodeproj \
  -scheme mreader \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath /tmp/MReaderBenchmarkDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build-for-testing

xcodebuild \
  -project mreader.xcodeproj \
  -scheme mreader \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath /tmp/MReaderBenchmarkDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  -only-testing:mreaderTests/TranslationFirstPageBaselineTests/testGenerateShirohagePageBaselineWhenOptedIn \
  test-without-building
```

The test logs one summary line with detected language, raw/resolved/line/grouped-bubble-block/physical-bubble/rejected counts and elapsed time. The JSON attachments contain the complete block-level result and runtime provenance.

## Human verification: turn the candidate into real gold

Open the source image and `sample_shirohage_manga.gold.json` side by side. For every translatable text region:

1. **Coverage:** add any missed dialogue/narration/SFX region and delete false text detections.
2. **Source text:** correct the Japanese text character by character. Do not copy the model's translation back into the source field.
3. **Geometry:** correct normalized `rect` values (`x`, `y`, `width`, `height`, all relative to the page in the same coordinate convention used by the benchmark).
4. **Reading order:** assign `readingOrder` according to the actual manga reading sequence, not the OCR output order.
5. **Bubble grouping:** lines in the same physical speech balloon share one `bubbleID`; text with no real balloon remains independent rather than receiving a fabricated bubble.
6. **Reference translation:** optionally add a human-reviewed Simplified Chinese translation under `referenceTranslations[regionID]`. Multiple natural translations can be valid; this field is a review anchor, not an automatic naturalness score.
7. Explicitly resolve `expectedPageState` from `unknown` to `completed`, `partial`, `noText` or `failed` based on the human review.
8. After the entire page has been checked, set `verificationStatus` to `humanVerified`.
9. Only then change the corresponding manifest sample from `pending` to `ready`.

A `ready` page whose annotation is still `candidate` must fail the benchmark contract tests.

## What to inspect in the app

For an end-to-end translation check, import the fixture as a one-page comic (or otherwise open the page in mReader), then:

- source language: Japanese;
- target language: Simplified Chinese;
- enable AI translation;
- use your normal provider/model and record which one you used;
- run the same page at least twice when checking consistency.

Check the following separately rather than giving one subjective score:

- every real dialogue/narration region is found;
- no artwork is hallucinated as text;
- multi-line text from one bubble stays together;
- adjacent different bubbles are not merged;
- reading order matches the page;
- negation, names, quantities and tone survive translation;
- no translated text becomes microscopic, clipped or escapes its safe region;
- in-place presentation is used only for reliable dialogue when enabled; uncertain text uses assist overlay and SFX remains annotation-first;
- note total translation time and obvious retries/failures.

Simulator and physical-device OCR can differ because Apple Vision/ImageAnalyzer behavior is runtime-dependent. For product-quality judgment, repeat the page on the iPhone/iPad you actually read on and treat that as a separate baseline rather than assuming simulator output is identical.
