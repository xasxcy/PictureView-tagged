# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Binary modification / reverse engineering** project targeting **PictureView 2.3.4** (by wl879, `com.zouke.PictureView`), a closed-source macOS image viewer. Injects Finder color-tag functionality via a dylib without modifying the original binary.

The app is installed at `/Applications/PictureView.app`. `PictureView_2.3.4.dmg` is the unmodified reference (gitignored).

## Build

```bash
bash build.sh          # → build/PictureView.app
bash build.sh dmg      # → dist/PictureView_tagged.dmg
bash build.sh install  # → /Applications/PictureView.app (requires permission)
```

`build.sh` copies from `/Applications`, compiles `src/PVTagPlugin.m` as a universal dylib, injects `LC_LOAD_WEAK_DYLIB` via `tools/inject_macho.py`, ad-hoc signs, and clears quarantine.

## Source Layout

| Path | Role |
|------|------|
| `src/PVTagPlugin.m` | Plugin source (ObjC ARC, single file) |
| `tools/inject_macho.py` | Adds LC_LOAD_WEAK_DYLIB to fat Mach-O in-place |
| `build.sh` | One-shot build script |
| `PRD.md` | Feature requirements and implementation status |

## Target App Key Facts

- **Language**: Swift + ObjC mixed, symbols stripped
- **Architecture**: Universal Binary (x86_64 + arm64)
- **Hardened Runtime**: enabled — `DYLD_INSERT_LIBRARIES` does NOT work; must inject via LC_LOAD_WEAK_DYLIB + re-sign
- **Sandbox**: NOT sandboxed
- **Bundle ID**: `com.zouke.PictureView`, Team: `89KW4ZBND8`

## Relevant Internal Classes

| Class | Superclass | Role |
|-------|-----------|------|
| `PictureNav` | `NSScrollView` | Sidebar (flat directory list, siblings of current dir) |
| `TableView` | `NSScrollView` | Table container inside PictureNav |
| `GalleryView` | `NSScrollView` | Main gallery showing children of current dir as cards |
| `GalleryDocument` | `NSView` | Gallery content view; renders items via CALayer (subviews=0) |
| `GalleryPictureCard` | `NSView` | Individual folder card in the gallery |
| `PictureBody` | `NSView` | Main body/content area |
| `PictureWindow` | `NSWindowController` | Main window controller |
| `Scanner` | Swift object | Model object holding directory info; `url` ivar has size=0 (Swift resilient), `directory` ivar has size=8 (ObjC ref, untested) |

## Plugin Architecture (`src/PVTagPlugin.m`)

### Hooks Installed (8 total)

| # | Hook | Purpose |
|---|------|---------|
| 1 | `NSView.menuForEvent:` | Primary context menu intercept |
| 2 | `-[NSMenu popUpMenuPositioningItem:atLocation:inView:]` | Programmatic popup path |
| 3 | `+[NSMenu popUpContextMenu:withEvent:forView:]` | Classic popup path |
| 4 | `+[NSMenu popUpContextMenu:withEvent:forView:withFont:]` | Classic popup path variant |
| 5 | `NSView.rightMouseDown:` | Caches `gLastRightClickView` / `gLastRightClickEvent` |
| 6 | `NSWorkspace.activateFileViewerSelectingURLs:` | URL interception |
| 7 | `NSView.drawRect:` | Draws tag dots on gallery cards (via associated URL) |
| 8 | `NSFileManager.contentsOfDirectoryAtURL:…` | Pre-populates `gTagCache` + `gNameToURLCache` |

### URL Resolution Strategy

Swift value type `Scanner.url` (size=0) cannot be read via ObjC runtime. Instead:

1. **Data source lookup**: `items[row].url` — works if model object is ObjC-compatible
2. **Cell text + name cache**: `pvTextFromView(cell)` → `gNameToURLCache[name]` — works once NSFileManager hook has run
3. **NSWorkspace intercept** (most reliable): programmatically trigger "在访达中打开" menu item with `gInterceptMode=YES`, capture `activateFileViewerSelectingURLs:` call

### Finder Tag Write Strategy (two-step)

Direct `setxattr` alone does not notify Finder's UI. Two steps required:

```objc
// Step 1: Notify Finder (writes "Name\n0", triggers UI refresh)
[url setResourceValue:@[@"绿色"] forKey:NSURLTagNamesKey error:nil];

// Step 2: Overwrite xattr with color index (for colored folder icon)
setxattr(path, "com.apple.metadata:_kMDItemUserTags", bplist_data, len, 0, 0);
// stored format: "绿色\n2"  (name + "\n" + fileLabels index)
```

Tag names use `NSWorkspace.fileLabels` (system-localized): indices `[6,7,5,2,4,3,1]` map to Red/Orange/Yellow/Green/Blue/Purple/Gray display order.

### Sidebar Tag Dots

`pvRefreshTableTagDots()` walks the window's view hierarchy for `NSTableView` instances, reads each visible row's cell text via `pvTextFromView()`, looks up URL in `gNameToURLCache`, and injects a `PVTagDotView` (transparent NSView, `hitTest:→nil`) as a subview of the row view. Called after NSFileManager hook and after each `toggleTag`.

Note: `NSTableRowView.drawRect:` swizzle was ineffective — PictureView uses a custom row view subclass that overrides `drawRect:` without calling super.

### Known Limitations

- **Gallery card dots on initial load**: GalleryPictureCard renders via CALayer (no NSTextField subviews), so `pvTextFromView` returns nil; dots only appear after a right-click on the card
- **Sidebar initial load**: depends on NSFileManager hook firing; if PictureView uses other directory-listing APIs the cache stays empty
- **Multi-select**: right-click menu only handles single URL; multi-select tagging not implemented
