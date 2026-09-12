# OCR fixture attribution

`japanese_vertical_tateyoko.png` is Wikimedia Commons' `Tateyoko.png`, an
example showing Japanese horizontal and vertical writing. It was created by
Nanshu and released worldwide into the public domain.

- Source: https://commons.wikimedia.org/wiki/File:Tateyoko.png
- Original file: https://commons.wikimedia.org/wiki/Special:FilePath/Tateyoko.png
- License: public domain (`PD-self`)
- Expected vertical sentence: `ノートを買った。`

`japanese_vertical_tateyoko_crop.png` is the public-domain vertical-writing
column cropped from that source page so the golden OCR test does not dilute
the result with unrelated horizontal labels. The crop retains the original
pixels and license.

The larger `manga_page_publicdomainq.png` fixture is a CC0 manga-drawing page
from Wikimedia Commons. Visual review found no human-verified translatable manga
dialogue on the page, so it is intentionally a **negative `noText` gold fixture**.
It must not be used as Japanese OCR/translation ground truth. Its page-level gold
annotation is `manga_page_publicdomainq.gold.json`.

`sample_shirohage_manga.jpg` is Wikimedia Commons' `Sample of SHIROHAGE MANGA.jpg`,
a Japanese speech-balloon manga example by しんぎんぐきゃっと, licensed under
CC BY-SA 4.0. The repository stores the original file unchanged (SHA-1
`8c828fc750e946ce94038a00782cbe115537c15e`). The image remains licensed under
CC BY-SA 4.0 and is not relicensed under the repository's source-code license.

- Source: https://commons.wikimedia.org/wiki/File:Sample_of_SHIROHAGE_MANGA.jpg
- License: https://creativecommons.org/licenses/by-sa/4.0/
- Author: しんぎんぐきゃっと
- Fixture status: `pending` until human gold regions, reading order, grouping and
  reference translations are completed.

## Translation quality benchmark policy

`translation_quality_manifest.json` is the canonical inventory for fixtures
used by the translation quality benchmark. A sample may be reported in quality
metrics only when `annotationStatus` is `ready`. `pending` means the image is
licensed and available but its human gold annotations are incomplete; CI must
not infer or fabricate missing OCR text, reading order, translation, or layout
ground truth.

The benchmark intentionally separates metrics instead of reducing translation
quality to one score:

- detection recall for human-marked text regions;
- OCR character error rate (CER), with layout whitespace excluded by default;
- reading-order pairwise accuracy plus coverage;
- terminology/name drift without assuming one uniquely correct translation;
- targeted partial-recovery precision/recall and stability of already-successful translations;
- unreadable-font, overflow and safe-region escape rates;
- P50/P95 latency, actual request count and observed/estimated provider cost.

Naturalness still requires bilingual human review over licensed multi-page
samples. A single reference sentence or model self-rating must not be reported
as a naturalness percentage.
