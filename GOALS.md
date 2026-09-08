# ScreenCap goals — round 2

Each goal is one orchestrated task with its own worktree. A goal is done when its acceptance
criteria hold, the project builds with zero errors, and the work is committed on its branch.
The coordinator merges into `main`, rebuilds, and pushes after each completed goal.

## G1 · Scrolling capture (⇧⌘0, All-in-One "Scroll")
- Drag a region (or click a window) → ScreenCap scrolls the content itself (scroll-wheel events
  posted to the region) and stitches successive frames into one tall PNG until the content stops
  changing, a max height is reached, or the user presses Esc / clicks Stop.
- Overlap detection is image-based (no accessibility API): the stitched image has no duplicated
  or missing rows on a typical web page or chat window with a fixed header.
- Result goes through the normal post-capture path (Quick Access, clipboard, autosave).
- Progress/stop UI is a small floating panel; the app never activates itself.

## G2 · Background & padding tool (editor)
- New "Background" tool in the annotation editor: padding (0–200 pt), corner radius, drop shadow,
  and a background chooser: none / solid color / 8 preset gradients / macOS-style mesh-ish gradient.
- The exported image (Copy / Save / Save As) includes the background and padding; the on-canvas
  preview matches the export exactly.
- Settings are remembered between editor sessions (UserDefaults, no new Settings tab needed).

## G3 · Capture history window
- Menu bar → "Capture History" (hotkey unassigned by default): a window showing recent captures as
  a thumbnail grid (newest first) with type badges (image / video / gif), time, and size.
- Each item: Copy, Save, Annotate, Pin, Show in Finder, Delete (removes file + entry). Double-click
  opens the file. Search field filters by date/type text.
- History persists across launches (metadata JSON in Application Support; files remain in the temp
  or save folder; missing files are pruned on load). Cap at 200 entries.

## G4 · Annotation tools upgrade (after G2)
- New tools: Crop (drag a rect, apply → canvas shrinks), Spotlight (dims everything except the
  chosen rect/ellipse), curved arrow, Black-out redaction (solid rect).
- Smart redaction: a "Detect sensitive text" action that runs OCR (OCRController.recognizeText)
  and proposes pixelate rectangles over emails, phone numbers, IPs, and API-key-like tokens.
- All new tools export identically to the canvas via AnnotationRenderer; undo/redo works.

## G5 · Recording upgrades
- Countdown (0/3/5/10 s, Settings → Recording) shown as a large centered number before recording.
- Microphone capture toggle (Settings) mixed into the mp4 alongside optional system audio.
- Click highlight option: a ring is drawn around the cursor on mouse-down in the recording.
- Recording controls panel gains a pause/resume button when the API allows, or omits it cleanly.

## G6 · Distribution
- `scripts/release.sh <version>`: Release build signed with "Developer ID Application",
  hardened runtime on, notarized with `notarytool` (keychain profile name from scripts/local.env),
  stapled, packaged as a dmg (hdiutil) and zip, with SHA-256 printed.
- Bumps CFBundleShortVersionString/CFBundleVersion in project.yml, tags `v<version>`, and prints
  the `gh release create` command (does not run it).
- README (en/ko) gets a "Releases" section explaining installation and how to run the script.
