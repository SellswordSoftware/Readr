# Readr Scroll Diagnostics

Copy `scroll-diagnostics.epub` into the Playdate's `Data/com.sellswordsoftware.readr`
folder. Open Readr and enter Library to discover it. Open the book, then select
Scroll in the system menu's Settings. Start with Newsleak Serif; repeat with
Roobert 20 Medium. Test the current app before applying rendering fixes.

Use Library's Chapters action to jump between the four sections:

| Chapter | Purpose |
| --- | --- |
| 1. ASCII control | Ordinary markup and plain ASCII. Look for page-boundary pops without Unicode. |
| 2. Unicode stress | Accents, curly quotes, em dashes, and ellipses exercise the suspected SDK character-count mismatch. |
| 3. Buffer stress | Plain ASCII with long invisible XML comments deliberately slows page preparation to expose loading gaps and overlapping dots. |
| 4. Combined stress | Unicode and slow preparation together. |

Scroll slowly across at least three page boundaries, then scroll quickly and
reverse across those same lines. Each source line has a stable label (`A0001`,
`U0001`, `B0001`, or `C0001`); a source line may wrap depending on the font.
Notice whether text changes while reversing, symbols appear beyond the written
punctuation, loading dots overlap a line, or the next line appears suddenly.
Pause to let decoding catch up, then repeat the movement.

Accents, curly punctuation, and ellipses in chapters 2 and 4 are intentional.
Missing font glyphs can legitimately become question marks or ASCII fallbacks.
Chapters 1 and 3 contain no printed dots in their numbered lines: any `...`
there is the app's loading indicator.

Chapters 3 and 4 intentionally exaggerate the buffering problem. They are valid
EPUB content, but their invisible padding makes them slower than ordinary books.
The Unicode defect depends on font coverage and surrounding memory, so this
fixture does not guarantee every visual symptom will reproduce.

For a useful comparison, record the chapter, numbered line, font, scroll
direction and speed, and whether the result matches the original problem book.

Regenerate and validate the ZIP/XML structure with:

```sh
python3 tests/generators/make_scroll_diagnostics_fixture.py
```
