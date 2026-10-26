# Split

A file converter and editor for the macOS menu bar. Start dragging files, tap a key, and drop them on a wheel of conversions and tools. Split uses open-source engines and the frameworks built into macOS. There are no accounts, limits or online services: everything happens on your Mac.

## Requirements

- macOS 13 or later, on Apple silicon or Intel (the app is a universal binary)
- [Homebrew](https://brew.sh), only for audio and video, WebP, JPEG XL and metadata removal

## Install

1. Open `Split-<version>.dmg` and drag **Split** onto **Applications**.
2. Open Split from Applications. Without a Developer ID signature, macOS blocks the first launch: open **System Settings › Privacy & Security**, click **Open Anyway** next to Split, and confirm. This is needed only once.
3. Install the free engines in Terminal (Settings › Engines shows the exact command for whatever is missing):

   ```bash
   brew install ffmpeg webp jpeg-xl exiftool
   ```

   There's no need to reopen Split afterwards. Everything else uses macOS itself.
4. Optional: **Settings › Engines › Terminal** gives the command that links `splitapp` to the app, so it works in Terminal.

## Use

1. Start dragging files (Finder, the desktop, Mail…).
2. While still dragging, tap a key once:
   - **⇧ Shift**: the **conversion** wheel (formats)
   - **⌘ Command**: the **tools** wheel (editors, compress, PDF, sound…)
   - **⌥ Option**: the **actions** wheel (AirDrop, shelf, copy, move, Terminal)
3. Drop on the slice you want. The result is saved next to the original, which is never changed.

It also works without dragging: in the menu bar, choose **Convert Files…**, **Tools…** or **Actions…** and then the files, or use **Open With › Split** in Finder. The wheel then follows the mouse (press highlights, release confirms) and the keyboard (arrows, Return, Esc). Clicking outside closes it. The keys can be changed in **Settings › Shortcuts**.

### Groups

Slices that do similar things share one slice with three dots on its rim, for example **Compress** (compress, compress to a size, ZIP) or **Sound**. Click it, or rest on it for half a second while dragging, and it opens as a wheel of its own. **Esc**, **Delete** or the centre go back.

### Settings › Wheels

- **Order and visibility:** drag slices to reorder them, untick the ones you don't use.
- **Groups:** select slices (⌘-click) and click **Group**. Open a group to rename it, reorder its slices, add or remove them, or ungroup it. **Restore Defaults** brings back the original wheel.
- **Size:** from Extra Small to Extra Large. Icons always stay on one ring; a name too long for a small slice ends in “…”, and the centre shows it whole.
- **Names under icons:** turn it off for a wheel with icons only.

The preview shows the result as you change it.

## Editors

| Editor | For | What it does |
|---|---|---|
| Crop | Images | Fixed or free proportions, rotate 90°, flip |
| Annotate and Cover | Images | Arrows, lines, shapes, text, numbers, highlighter; blur, pixelate or black out areas; blur faces automatically (Vision) |
| Adjust | Images | Exposure, contrast, saturation, temperature and filters, with a before/after comparison |
| Add Background | Images | Padding, corners, shadow, gradients, colour or blurred image, output proportion |
| Collage | 2 or more images | Row, column or grid, spacing and background |
| Edit Media | Video and audio | Trim, speed, volume, fades, crop, rotate, cover areas, export a GIF, save frames |
| Organize PDF | PDF | Reorder, rotate, duplicate and delete pages, add other PDFs or images, extract pages |

Editors save a copy next to the original (for example `photo (cropped).jpg`). Closing with unsaved changes asks first.

## One-click tools

Compress (image, video, audio and PDF) or compress to a target size, remove metadata, remove background (Vision), combine into a PDF, split a PDF, extract archives, create a ZIP, normalize loudness (−16 LUFS, EBU R128), convert to mono, cut silences, remove audio, join videos, frames (12 PNG), audio to video (waveform MP4) and read QR codes (the text goes to the clipboard).

**Actions:** AirDrop, shelf (keeps files in a floating panel to drop later, or drag them all at once), copy, copy paths, move and open Terminal in the folder.

**Activity…** in the menu bar lists recent jobs and their results.

## What it converts

| From | To | Engine |
|---|---|---|
| JPG PNG WebP JPEG XL HEIC AVIF TIFF BMP GIF ICO SVG | JPG PNG WebP JPEG XL HEIC AVIF TIFF BMP GIF ICO PDF (GIF also to MP4/WebM) | ImageIO, cwebp, gif2webp, cjxl |
| MP3 M4A WAV FLAC OGG Opus AIFF WMA | the same | ffmpeg |
| MP4 MOV M4V MKV WebM AVI WMV | MP4 MOV MKV WebM AVI WMV GIF and every audio format | ffmpeg (without re-encoding when possible) |
| DOCX DOC ODT RTF RTFD TXT HTML Markdown EPUB | PDF DOCX ODT RTF TXT HTML EPUB Pages | Cocoa, Word (optional), Split's own EPUB and Markdown, Pages |
| PDF | PNG JPG TXT DOCX RTF HTML EPUB | PDFKit, with OCR (Vision) for scans |
| Pages | PDF DOCX EPUB TXT RTF | Pages |
| CSV TSV XLSX, and XLS ODS Numbers with Numbers or Excel | XLSX CSV TSV HTML PDF JSON | Split's own XLSX reader and writer, Excel (optional) |
| JSON | CSV TSV XLSX HTML XML YAML | Split's own |
| XML | JSON | Split's own |
| PPTX PPT Keynote | PDF | PowerPoint, Keynote or LibreOffice |
| SRT VTT | VTT SRT | ffmpeg |
| ZIP TAR TAR.GZ RAR 7Z | ZIP TAR TAR.GZ | ditto, zip, tar (libarchive) |

The XLSX it writes keeps numbers, dates, percentages and formulas, with a bold header, a frozen first row and column widths. A European CSV (`;` and decimal comma) is read as such. Excel dates, including the Mac's 1904 system, are converted correctly. When a conversion can't keep something (fonts, comments, animation), the result says what was lost.

## Look

- The interface is dark: the wheel is black and the slice under the pointer turns white. Settings › General also offers a **Glass** backdrop for the wheel.
- Springs are critically damped and interruptible, the wheel opens at the pointer, press highlights and release confirms, haptics only when snapping and confirming, and sounds only at the end and on errors (they can be turned off).
- Reduce Motion, Reduce Transparency and Increase Contrast are respected. Text on the highlight has a contrast of at least 4.5:1 in light and dark (checked by the tests).
- The interface is in English, Portuguese, French and Spanish.

## Errors explained

Every failure says what happened, why, and what to do. For example: the file was moved, is empty or is still in iCloud; the extension doesn't match the content (“it's a JPEG with a .png extension”); the disk is full; the folder can't be written to; the video is incomplete; the PDF has a password; macOS didn't allow Word to be automated; the archive tries to write outside its folder. The technical details are in a report that can be copied.

## Privacy and security

Split doesn't use the Internet, and the tests check it rather than just promise it:

- The binary links neither Network.framework, CFNetwork nor WebKit, and calls no network APIs (URLSession, sockets).
- ffmpeg may only open local files (`-protocol_whitelist file`), so a playlist disguised as a video can't send it online.
- macOS imports HTML, Markdown, EPUB and the “web pages” Word saves as `.doc` with WebKit, which would fetch remote images, styles and fonts from a system service that no block inside the app can stop. So before the import, Split removes everything in the document that points elsewhere: it decodes entities and escapes first, and inlines local stylesheets after cleaning them too.
- XML is read without external entities (no XXE) and with an expansion limit.
- Archives can't write outside their destination folder, and links that point outside it are dropped.
- File names never go through a shell, and paths sent to AppleScript are quoted.

The tests prove it with a local network trap: every hostile document points at it, and the result must be zero connections.

**An exception you choose:** with “Use Word, Excel and PowerPoint when installed” on, those conversions are done by Microsoft's apps. The file never leaves the Mac, but those apps follow their own rules and may, for example, load images or templates the document links to. Turn the option off to use only the macOS converters.

## Terminal

```bash
splitapp convert webp ~/Desktop/*.heic
splitapp targets report.docx
splitapp tool compress video.mov
splitapp doctor
```

## Build and test

You need Apple's Command Line Tools (`xcode-select --install`); Xcode isn't required.

```bash
./build.sh        # build/Split.app
./make-dmg.sh     # build/Split-<version>.dmg and its .sha256
Tests/run.sh      # every test
```

`make-dmg.sh` signs with a Developer ID and notarizes when `SIGN_IDENTITY` and `NOTARY_PROFILE` are set (see the script); otherwise the app keeps an ad hoc signature.

`Tests/run.sh` builds the app and the tests, generates every sample from scratch (nothing is downloaded) and runs 161 tests with about 76,000 checks:

- **Conversion:** every wheel format for every sample, with the result's content checked (colours, pages, duration, codecs, text and accents).
- **Tools and editors:** compress, metadata, background, PDF, ZIP, loudness, silences, video and every editor.
- **Errors:** explanations for missing, empty, protected, damaged or disguised files.
- **Security:**
  - hostile HTML, Markdown, SVG, EPUB, DOCX and RTF, with zero network connections;
  - disguised playlists, XXE and “billion laughs”;
  - zip slip, file names with commands, and an audit of the binary.
- **Interface:** the wheel's layout at every size and language, groups, keyboard and mouse, springs, contrast, symbols, HUD, menus and shortcuts, plus snapshots of every window in light and dark in `build/test-run/_captures`.
- **Localization:** every interface text is translated, and no translation is left unused.

Pass a filter to run only part of it, for example `Tests/run.sh Security`. `Tests/run.sh --intel` runs the tests under Rosetta, as on an Intel Mac. The Office tests open Word, Excel and PowerPoint, and macOS asks for permission the first time, so they only run when asked:

```bash
SPLIT_OFFICE=1 Tests/run.sh Office
```

## Limitations

- An EPUB made from a DOCX or a PDF has no images.
- PPTX to PDF needs PowerPoint, Keynote or LibreOffice.
- The first conversion with Pages, Numbers, Keynote or Office makes macOS ask for Automation permission.
- Remove background needs macOS 14 or later (Vision).

## Layout

| Folder | Contents |
|---|---|
| `Sources/App` | Entry point, menu bar and the `splitapp` command |
| `Sources/Core` | Formats, jobs, output naming, engines, settings, errors, localization, wheel arrangement |
| `Sources/Converters` | Images, media, documents, EPUB, Markdown, spreadsheets, JSON, archives, Office bridge |
| `Sources/Tools` | One-click tools and file actions |
| `Sources/Editors` | The editors and their shared kit |
| `Sources/Interface` | Drag gesture, wheel and its layout, HUD, shelf, settings, theme |
| `Tests/` | Its own harness (the Command Line Tools have no XCTest), generated samples and suites |
| `Resources/` | Icon, entitlements and translations |
