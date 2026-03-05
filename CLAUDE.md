# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **binary modification / reverse engineering** project targeting **PictureView 2.3.4** (by wl879, `com.zouke.PictureView`), a closed-source macOS image viewer. The goal is to inject new functionality via a dylib without access to source code.

The app is installed at `/Applications/PictureView.app`. The DMG (`PictureView_2.3.4.dmg`) is kept as the unmodified reference.

## Target App Key Facts

- **Language**: Swift + ObjC mixed, symbols stripped
- **Architecture**: Universal Binary (x86_64 + arm64)
- **Hardened Runtime**: enabled (`flags=0x10000(runtime)`) — `DYLD_INSERT_LIBRARIES` does NOT work without re-signing
- **Sandbox**: NOT sandboxed (entitlements only contain team identifier)
- **Bundle ID**: `com.zouke.PictureView`, Team: `89KW4ZBND8`
- **Sparkle**: Uses Sparkle 1.27.1 for auto-update

## Relevant Internal Classes (from ObjC runtime metadata)

| Class | Superclass | Role |
|---|---|---|
| `PictureNav` | `NSScrollView` | Sidebar navigation (flat directory list) |
| `TableView` | `NSScrollView` | Likely the table inside PictureNav |
| `GalleryView` | `NSScrollView` | Main gallery area showing folder cards |
| `PictureGallery` | `NSView` | Gallery content view |
| `GalleryPictureCard` | `NSView` | Individual image cards |
| `PictureBody` | `NSView` | Main body/content area |
| `PictureWindow` | `NSWindowController` | Main window controller |
| `AppDelegate` | Swift object | App delegate |
| `PictureManager` | Swift object | Central manager, has `picWindow`, `_emitQueue` |

## Injection Architecture

The modification uses a **dylib injected via `LC_LOAD_WEAK_DYLIB`** load command added to the Mach-O binary.

### Build the Dylib
```bash
# From the dylib source directory
clang -fobjc-arc -framework Foundation -framework AppKit \
  -dynamiclib -o PVTagPlugin.dylib PVTagPlugin.m

# Or with Xcode
xcodebuild -scheme PVTagPlugin -configuration Release
```

### Inject Load Command (requires insert_dylib or optool)
```bash
# Copy app to working location first
cp -R /Applications/PictureView.app ./PictureView_patched.app

# Inject dylib (place dylib in app's Frameworks/ or MacOS/)
insert_dylib --weak --all-yes \
  @executable_path/../Frameworks/PVTagPlugin.dylib \
  ./PictureView_patched.app/Contents/MacOS/PictureView

# Ad-hoc re-sign (required after any binary modification)
codesign --remove-signature ./PictureView_patched.app
codesign -f -s - --deep ./PictureView_patched.app

# Clear quarantine
xattr -cr ./PictureView_patched.app
```

### Install
```bash
cp -R ./PictureView_patched.app /Applications/PictureView.app
```

## Finder Tag API

macOS tags are set via `NSURLTagNamesKey`. Standard color tag names: `Red`, `Orange`, `Yellow`, `Green`, `Blue`, `Purple`, `Gray`.

```objc
NSURL *url = [NSURL fileURLWithPath:folderPath];
[url setResourceValue:@[@"Red"] forKey:NSURLTagNamesKey error:nil];
// Clear tags:
[url setResourceValue:@[] forKey:NSURLTagNamesKey error:nil];
```

The target binary already references `_NSURLTagNamesKey`, confirming system compatibility.

## Swizzling Strategy

Since the binary is stripped Swift, use ObjC runtime introspection at launch to find the right view:

1. Hook `-[NSApplication applicationDidFinishLaunching:]` via `+load` in the dylib
2. Walk the window's view hierarchy to find views whose class name matches `_TtC11PictureView10PictureNav` (the mangled Swift name)
3. Find the `NSTableView` child inside it
4. Swizzle `menuForEvent:` to inject tag menu items
5. Do the same for `GalleryView` / `GalleryPictureCard` to cover the main area right-click menu (image 3 context menu)

To get the folder URL from a clicked row, inspect the table's `dataSource` or `delegate` at runtime — look for properties named `url` or `path` on the row's represented object (the `ImageRef` class has a `url` property).
