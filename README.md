# ScreenCap

**English** · [한국어](README.ko.md)

A CleanShot X–inspired screenshot and screen recording app for macOS, written in Swift (AppKit + SwiftUI) on top of ScreenCaptureKit.

## Features

- **Capture** — fullscreen, area (drag), or window (hover + click) from the menu bar or global hotkeys. The front app keeps focus, so windows look normal in the shot. Retina-aware, cursor optional.
- **All-in-One** — ⇧⌘8 opens one overlay with a mode toolbar (Area · Window · Fullscreen · Pin · Record · Text). Switch with a click or the A/W/F/P/R/T keys (or 1–6); it remembers the last mode you used.
- **OCR** — ⇧⌘7 drags over any text (or clicks a window) and copies it as layout-preserving plain text. Korean, English, Japanese and Chinese are enabled; QR codes are decoded too, with an Open button for URLs.
- **Pin** — ⇧⌘4 grabs an area (or window) and leaves it floating above every app and Space, right where it was. Drag it aside, resize from the edges, scroll to change opacity, Esc or ✕ to close. Handy for keeping a chat or spec in view while you work. Lock a pin (⌘L or its menu) to make it click-through and immovable, ⌘+scroll or pinch to zoom 25–400%, double-click to reset, arrow keys to nudge, ⇧⌘9 to hide/show every pin. The menu bar's Pins submenu lists them, unlocks locked ones, and reopens the last closed pin.
- **Quick Access overlay** — captures stack up in the bottom-left corner. Hover for Copy / Save / Annotate / Pin / GIF, drag the thumbnail straight into another app, or let it auto-dismiss. While hovering a card, single keys act on it: C copy, S save, ⇧S save as, E annotate, P pin, G GIF, O open, F Finder, ⌫ dismiss, ⌘⌫ dismiss all.
- **Annotation editor** — arrow, line, rectangle, ellipse, pen, highlighter, text, pixelate, and numbered counters. Undo/redo, move with the select tool, single-key tool shortcuts (A, L, R, O, P, H, T, B, N, V).
- **Screen recording** — record any area or window to H.264 `.mp4` (optionally with system audio), then convert to a looping GIF from Quick Access.

Default shortcuts (change them in Settings → Shortcuts):

| Action | Shortcut |
| --- | --- |
| Capture Fullscreen | ⇧⌘1 |
| Capture Area | ⇧⌘2 |
| Capture Window | ⇧⌘3 |
| Pin Area (floating reference) | ⇧⌘4 |
| Record Screen (start/stop) | ⇧⌘5 |
| Open Last Capture | ⇧⌘6 |
| Copy Text (OCR) | ⇧⌘7 |
| All-in-One | ⇧⌘8 |
| Hide/Show Pins | ⇧⌘9 |

⇧⌘3/4/5 are also macOS's built-in screenshot shortcuts, which take priority. Turn them off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots (the Shortcuts tab in ScreenCap warns you and links there).

## Requirements

- macOS 15 (Sequoia) or later — uses `SCScreenshotManager` and `SCRecordingOutput`.
- Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording). Grant it, then relaunch the app.

## Build & run

```sh
./scripts/run.sh          # xcodegen + xcodebuild (Debug) + launch
```

`scripts/build.sh` only builds; the `.app` lands in `build/Build/Products/Debug/`. To work in Xcode, run `xcodegen generate` and open `ScreenCap.xcodeproj` (it's git-ignored; `project.yml` is the source of truth).

Development flags:

```sh
ScreenCap.app/Contents/MacOS/ScreenCap --open-editor path/to/image.png   # open the annotation editor directly
ScreenCap.app/Contents/MacOS/ScreenCap --debug-overlay                    # show the selection overlay, print the result
```

## Project layout

```
ScreenCap/
  App/          entry point, app delegate, menu bar item, main menu
  Capture/      ScreenCaptureKit engine, window enumeration, selection overlay, coordinator, pin windows
  Recording/    SCStream recorder, on-screen recording controls, GIF export
  QuickAccess/  bottom-left thumbnail stack (NSPanel + SwiftUI)
  Editor/       annotation model, shared CG renderer, AppKit canvas, editor window
  Settings/     UserDefaults-backed preferences and the Settings window
  Hotkeys/      Carbon RegisterEventHotKey wrapper and recorder UI
  Support/      file store, clipboard, permissions, OCR, extensions
```

Design notes:

- Overlays and Quick Access are **non-activating `NSPanel`s**, so ScreenCap never steals focus and the app you're capturing doesn't dim.
- Every ScreenCap window is excluded from the `SCContentFilter`, so the overlay, frame, and recording controls never appear in the output.
- Annotations are rendered by one Core Graphics code path (`AnnotationRenderer`) for both the live canvas and the exported image, in y-down image-pixel coordinates.
