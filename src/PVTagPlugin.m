// PVTagPlugin.m
// Injects Finder-style color-tag support into PictureView's context menus,
// and displays tag color dots next to folder icons in the sidebar and gallery.
//
// Hook strategy:
//   Primary  – swizzle NSView.menuForEvent: (catches menu creation before it's shown)
//   Fallback – swizzle +[NSMenu popUpContextMenu:withEvent:forView:] (classic path)
//
// UI: a single custom NSMenuItem showing 7 colored circles in a row, like Finder.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/xattr.h>

// ─── Tag color definitions ────────────────────────────────────────────────────
// Standard macOS Finder tag names and their color indices (stored as "Name\nIndex" in xattr)
// Index: 0=none 1=gray 2=green 3=purple 4=blue 5=yellow 6=red 7=orange

// NSWorkspace.fileLabels indices for each display-order slot.
// Display order: Red, Orange, Yellow, Green, Blue, Purple, Gray
// fileLabels index: 0=none 1=gray 2=green 3=purple 4=blue 5=yellow 6=red 7=orange
static const NSInteger kTagDisplayIndices[] = {6, 7, 5, 2, 4, 3, 1};

// Fallback English names used when fileLabels is unavailable
static NSString * const kTagFallbackNames[] = {
    @"Red", @"Orange", @"Yellow", @"Green", @"Blue", @"Purple", @"Gray"
};

// System-localized tag names in display order (e.g. "红色","橙色",… on zh-Hans)
static NSArray<NSString *> *tagNames(void) {
    NSArray *labels = [[NSWorkspace sharedWorkspace] fileLabels];
    if (!labels || labels.count < 8) {
        return @[@"Red", @"Orange", @"Yellow", @"Green", @"Blue", @"Purple", @"Gray"];
    }
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:7];
    for (int i = 0; i < 7; i++) {
        NSString *n = labels[kTagDisplayIndices[i]];
        [names addObject:(n.length > 0) ? n : kTagFallbackNames[i]];
    }
    return names;
}

static NSArray<NSColor *> *tagColors(void) {
    return @[NSColor.systemRedColor, NSColor.systemOrangeColor, NSColor.systemYellowColor,
             NSColor.systemGreenColor, NSColor.systemBlueColor, NSColor.systemPurpleColor,
             NSColor.systemGrayColor];
}

// Finder color index for a tag name.
// Looks up in NSWorkspace.fileLabels so "绿色" → 2, "Green" → 2, etc.
static int tagColorIndex(NSString *name) {
    NSArray *labels = [[NSWorkspace sharedWorkspace] fileLabels];
    for (NSInteger i = 1; i < (NSInteger)labels.count; i++) {
        if ([labels[i] isEqualToString:name]) return (int)i;
    }
    // Fallback: match English names
    NSDictionary *fb = @{@"Red":@6, @"Orange":@7, @"Yellow":@5,
                         @"Green":@2, @"Blue":@4, @"Purple":@3, @"Gray":@1};
    NSNumber *n = fb[name];
    return n ? n.intValue : 0;
}

// ─── Finder tag xattr helpers ─────────────────────────────────────────────────
// Store tags directly as "Name\nColorIndex" in com.apple.metadata:_kMDItemUserTags
// so Finder shows colored folder icons.

#define FINDER_TAG_XATTR "com.apple.metadata:_kMDItemUserTags"

// Read raw stored tag strings (e.g. "Green\n2") from xattr
static NSArray<NSString *> *readRawTags(NSURL *url) {
    const char *path = url.fileSystemRepresentation;
    ssize_t size = getxattr(path, FINDER_TAG_XATTR, NULL, 0, 0, 0);
    if (size <= 0) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (getxattr(path, FINDER_TAG_XATTR, data.mutableBytes, size, 0, 0) < 0) return @[];
    NSArray *tags = [NSPropertyListSerialization propertyListWithData:data
                        options:0 format:nil error:nil];
    return [tags isKindOfClass:[NSArray class]] ? tags : @[];
}

// Strip \nColorIndex suffix to get display name
static NSString *displayName(NSString *raw) {
    NSRange r = [raw rangeOfString:@"\n"];
    return r.location != NSNotFound ? [raw substringToIndex:r.location] : raw;
}

// Write raw tag strings to xattr.
// Two-step: first use NSURLTagNamesKey to trigger Finder/Spotlight notifications
// (so Finder shows the colored dot immediately), then overwrite the xattr with
// the color-indexed format ("Name\nColorIndex") so Finder also tints the folder icon.
static BOOL writeRawTags(NSURL *url, NSArray<NSString *> *rawTags) {
    // Step 1: Notify Finder via Foundation API (writes "Name\n0", triggers UI refresh)
    NSMutableArray *displayNames = [NSMutableArray arrayWithCapacity:rawTags.count];
    for (NSString *raw in rawTags) [displayNames addObject:displayName(raw)];
    NSError *resErr = nil;
    BOOL notified = [url setResourceValue:displayNames forKey:NSURLTagNamesKey error:&resErr];
    NSLog(@"[PVTag] setResourceValue tags=%@ ok=%d err=%@", displayNames, notified, resErr);

    // Step 2: Overwrite xattr with proper color indices for colored folder icons
    if (rawTags.count == 0) {
        removexattr(url.fileSystemRepresentation, FINDER_TAG_XATTR, 0);
        return YES;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:rawTags
                       format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return NO;
    const char *path = url.fileSystemRepresentation;
    BOOL ok = setxattr(path, FINDER_TAG_XATTR, data.bytes, data.length, 0, 0) == 0;
    NSLog(@"[PVTag] setxattr ok=%d path=%s", ok, path);
    return ok;
}

// Get display names of current tags (strips color index)
static NSArray<NSString *> *currentTags(NSURL *url) {
    NSArray *raw = readRawTags(url);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *s in raw) [names addObject:displayName(s)];
    return names;
}

// ─── Caches ───────────────────────────────────────────────────────────────────
//
// gTagCache      — absolute path → [display tag name, ...]
//                  Populated by NSFileManager hook and toggleTag.
//
// gNameToURLCache — folder last-path-component → NSURL
//                  Populated by NSFileManager hook (all child dirs, not just tagged).
//                  Lets us map the text label in a row/card view to its real NSURL
//                  without needing to touch Swift ivars.

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gTagCache;
static NSMutableDictionary<NSString *, NSURL *>               *gNameToURLCache;

// Associated object keys (the address of these variables is the key)
static const char kURLAssocKey  = 0;   // NSView → NSURL (folder it represents)
static const char kURLTriedKey  = 0;   // NSView → @YES  (URL discovery already attempted)

// Update the tag cache entry for a single URL (called after any tag change)
static void cacheUpdate(NSURL *url) {
    if (!url.path.length) return;
    NSArray *tags = currentTags(url);
    @synchronized(gTagCache) {
        if (tags.count > 0)
            gTagCache[url.path] = tags;
        else
            [gTagCache removeObjectForKey:url.path];
    }
}

static BOOL toggleTag(NSURL *url, NSString *tagName) {
    NSArray *raw = readRawTags(url);
    int colorIdx = tagColorIndex(tagName);
    NSString *storedName = [NSString stringWithFormat:@"%@\n%d", tagName, colorIdx];

    // Remove any existing entry that matches by name OR by color index
    // (handles migration from old English tags like "Green\n2" → new "绿色\n2")
    NSMutableArray *updated = [NSMutableArray array];
    BOOL found = NO;
    for (NSString *r in raw) {
        NSString *rDisplayName = displayName(r);
        NSRange nl = [r rangeOfString:@"\n"];
        int rIdx = (nl.location != NSNotFound) ?
                   [[r substringFromIndex:nl.location + 1] intValue] : 0;
        if ([rDisplayName isEqualToString:tagName] || (colorIdx > 0 && rIdx == colorIdx)) {
            found = YES; continue; // remove (also migrates old English tags)
        }
        [updated addObject:r];
    }
    if (!found) [updated addObject:storedName];

    BOOL ok = writeRawTags(url, updated);
    if (ok) cacheUpdate(url);
    NSLog(@"[PVTag] toggleTag '%@'(idx=%d) %@ ok=%d",
          tagName, colorIdx, found ? @"removed" : @"added", ok);
    return ok;
}

// ─── Drawing helpers ──────────────────────────────────────────────────────────

// Draw small colored circles starting at 'origin', diameter 'size'.
// Caller is responsible for graphics state save/restore.
static void pvDrawTagDots(NSArray<NSString *> *tags, NSPoint origin, CGFloat size) {
    NSArray *colors = tagColors();
    NSArray *names  = tagNames();
    CGFloat x = origin.x;
    for (NSString *tag in tags) {
        NSUInteger idx = [names indexOfObject:tag];
        if (idx == NSNotFound) continue;
        [colors[idx] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, origin.y, size, size)] fill];
        x += size + 2.0;
    }
}

// Walk view hierarchy to find all NSTableViews and mark them for redraw.
static void pvMarkTableViewsNeedsDisplay(NSView *view) {
    if ([view isKindOfClass:[NSTableView class]]) {
        [view setNeedsDisplay:YES];
        return;
    }
    for (NSView *sub in view.subviews) pvMarkTableViewsNeedsDisplay(sub);
}

// Walk a view's subview tree to find the first non-empty NSTextField string value.
// Depth-limited to avoid performance issues on deeply nested hierarchies.
static NSString *pvTextFromView(NSView *view) {
    if (!view) return nil;
    // Check common cell view pattern first
    if ([view isKindOfClass:[NSTableCellView class]]) {
        NSString *s = [(NSTableCellView *)view textField].stringValue;
        if (s.length > 0) return s;
    }
    if ([view isKindOfClass:[NSTextField class]]) {
        NSString *s = [(NSTextField *)view stringValue];
        if (s.length > 0) return s;
    }
    // Recurse into subviews (max depth 4 is plenty for typical cell/card layouts)
    for (NSView *sub in view.subviews) {
        NSString *s = pvTextFromView(sub);
        if (s) return s;
    }
    return nil;
}

// Look up URL for a folder by its display name from the name cache.
static NSURL *pvURLFromName(NSString *name) {
    if (!name.length) return nil;
    NSURL *url = nil;
    @synchronized(gNameToURLCache) { url = gNameToURLCache[name]; }
    return url;
}

// ─── PVTagDotView – injected as subview into sidebar row views ────────────────
//
// A small transparent NSView that draws colored tag dots.
// Added directly as a subview to NSTableRowView (or whatever class PictureView
// uses for rows) so we bypass any drawRect: override in PictureView.

static const char kDotViewKey = 0;  // associated object key: rowView → PVTagDotView

@interface PVTagDotView : NSView
@property (nonatomic, copy) NSArray<NSString *> *tagList;
@end

@implementation PVTagDotView
- (void)drawRect:(NSRect)rect {
    // This is our own override; NSView.drawRect: swizzle will NOT interfere.
    pvDrawTagDots(self.tagList, NSMakePoint(0, 0), 8.0);
}
- (BOOL)isOpaque { return NO; }
// Pass all mouse events through to the underlying row view.
- (NSView *)hitTest:(NSPoint)p { return nil; }
@end

// Add or update a PVTagDotView inside containerView, right-aligned and centered.
static void pvUpdateTagDotViewInView(NSView *containerView, NSArray<NSString *> *tags) {
    PVTagDotView *dotView = objc_getAssociatedObject(containerView, &kDotViewKey);

    if (!tags || tags.count == 0) {
        if (dotView) {
            [dotView removeFromSuperview];
            objc_setAssociatedObject(containerView, &kDotViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    CGFloat dotSize = 8.0, gap = 2.0, margin = 8.0;
    CGFloat w = tags.count * dotSize + (tags.count - 1) * gap;
    CGFloat h = dotSize;
    CGFloat x = NSWidth(containerView.bounds) - w - margin;
    CGFloat y = (NSHeight(containerView.bounds) - h) / 2.0;

    if (!dotView) {
        dotView = [[PVTagDotView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
        [containerView addSubview:dotView positioned:NSWindowAbove relativeTo:nil];
        objc_setAssociatedObject(containerView, &kDotViewKey, dotView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[PVTag] injected dot view into %@", NSStringFromClass(containerView.class));
    } else {
        dotView.frame = NSMakeRect(x, y, w, h);
    }
    dotView.tagList = tags;
    [dotView setNeedsDisplay:YES];
}

// Walk the view hierarchy, find NSTableView instances, and inject/update tag dot
// subviews for every visible row whose folder name is in gNameToURLCache.
static void pvRefreshTableTagDots(NSView *root) {
    if ([root isKindOfClass:[NSTableView class]]) {
        NSTableView *tv = (NSTableView *)root;
        NSLog(@"[PVTag] pvRefreshTableTagDots: found %@ rows=%ld",
              NSStringFromClass(tv.class), (long)tv.numberOfRows);
        for (NSInteger row = 0; row < tv.numberOfRows; row++) {
            // rowViewAtRow:makeIfNecessary:NO only returns already-visible rows.
            NSView *rowView = [tv rowViewAtRow:row makeIfNecessary:NO];
            if (!rowView) continue;

            NSView *cell = [tv viewAtColumn:0 row:row makeIfNecessary:NO];
            NSString *name = pvTextFromView(cell);
            if (!name.length) continue;

            NSURL *url = pvURLFromName(name);
            if (!url) continue;

            NSArray *tags;
            @synchronized(gTagCache) { tags = gTagCache[url.path]; }
            pvUpdateTagDotViewInView(rowView, tags);
        }
        return; // don't recurse into table subviews
    }
    for (NSView *sub in root.subviews) pvRefreshTableTagDots(sub);
}

// ─── Finder-style color-dot row view ─────────────────────────────────────────
//
// Renders 7 filled circles matching Finder's tag picker.
// Active tag: filled circle + white checkmark.  Inactive: filled circle, slightly muted.

static const CGFloat kDot   = 14.0;
static const CGFloat kGap   = 6.0;
static const CGFloat kVPad  = 8.0;
static const CGFloat kHPad  = 14.0;

@interface PVTagRowView : NSView
@property (nonatomic, strong) NSURL *targetURL;
@property (nonatomic, assign) NSInteger highlightedIndex;
@end

@implementation PVTagRowView

- (instancetype)initWithURL:(NSURL *)url {
    NSUInteger n = tagNames().count;
    CGFloat w = kHPad * 2 + n * kDot + (n - 1) * kGap;
    CGFloat h = kVPad * 2 + kDot;
    self = [super initWithFrame:NSMakeRect(0, 0, w, h)];
    if (self) {
        _targetURL = url;
        _highlightedIndex = -1;
    }
    return self;
}

- (NSRect)dotRectAtIndex:(NSUInteger)i {
    CGFloat x = kHPad + i * (kDot + kGap);
    CGFloat y = kVPad;
    return NSMakeRect(x, y, kDot, kDot);
}

- (NSInteger)indexAtPoint:(NSPoint)p {
    for (NSUInteger i = 0; i < tagNames().count; i++) {
        NSRect r = NSInsetRect([self dotRectAtIndex:i], -2, -2);
        if (NSPointInRect(p, r)) return (NSInteger)i;
    }
    return -1;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSArray *names  = tagNames();
    NSArray *colors = tagColors();
    NSArray *active = currentTags(self.targetURL);

    for (NSUInteger i = 0; i < names.count; i++) {
        NSRect  r     = [self dotRectAtIndex:i];
        NSColor *c    = colors[i];
        BOOL    on    = [active containsObject:names[i]];
        BOOL    hover = ((NSInteger)i == self.highlightedIndex);

        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:r];
        if (on || hover) {
            [c setFill];
        } else {
            [[c colorWithAlphaComponent:0.65] setFill];
        }
        [circle fill];

        if (on) {
            NSBezierPath *check = [NSBezierPath bezierPath];
            CGFloat cx = NSMidX(r), cy = NSMidY(r), s = kDot * 0.22;
            [check moveToPoint:NSMakePoint(cx - s * 1.1, cy - s * 0.1)];
            [check lineToPoint:NSMakePoint(cx - s * 0.2, cy - s * 1.0)];
            [check lineToPoint:NSMakePoint(cx + s * 1.3, cy + s * 1.0)];
            [NSColor.whiteColor setStroke];
            check.lineWidth = 1.8;
            check.lineCapStyle = NSLineCapStyleRound;
            check.lineJoinStyle = NSLineJoinStyleRound;
            [check stroke];
        }

        if (hover && !on) {
            [[c colorWithAlphaComponent:0.9] setStroke];
            circle.lineWidth = 1.5;
            [circle stroke];
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx >= 0 && self.targetURL) {
        NSLog(@"[PVTag] toggling tag '%@' on %@", tagNames()[idx], self.targetURL.path);
        toggleTag(self.targetURL, tagNames()[idx]);
        [self setNeedsDisplay:YES];

        // Refresh sidebar dot subviews + redraw gallery cards
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSWindow *win in NSApplication.sharedApplication.windows) {
                pvRefreshTableTagDots(win.contentView);
                [win.contentView setNeedsDisplay:YES];
                for (NSView *sub in win.contentView.subviews)
                    [sub setNeedsDisplay:YES];
            }
        });
    }
}

- (void)mouseDown:(NSEvent *)event {
    // Required to receive mouseUp: — just consume the event
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.highlightedIndex = [self indexAtPoint:p];
    [self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways
        owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    self.highlightedIndex = [self indexAtPoint:p];
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    self.highlightedIndex = -1;
    [self setNeedsDisplay:YES];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

@end

// ─── Build the tag menu item ──────────────────────────────────────────────────

static NSMenuItem *makeTagMenuItem(NSURL *url) {
    PVTagRowView *view = [[PVTagRowView alloc] initWithURL:url];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"标签" action:nil keyEquivalent:@""];
    item.view = view;
    return item;
}

// ─── Track last right-clicked view (set by rightMouseDown: swizzle) ───────────

static NSView  *gLastRightClickView  = nil;
static NSEvent *gLastRightClickEvent = nil;

// ─── NSWorkspace URL interception ─────────────────────────────────────────────
// When gInterceptMode is YES, capture the URL but don't open Finder.

static BOOL    gInterceptMode   = NO;
static NSURL  *gInterceptedURL  = nil;

static void (*orig_activateFileViewer)(id, SEL, NSArray *) = NULL;

static void swiz_activateFileViewer(id self, SEL _cmd, NSArray *urls) {
    if (gInterceptMode) {
        gInterceptedURL = [(NSURL *)urls.firstObject copy];
        return;
    }
    orig_activateFileViewer(self, _cmd, urls);
}

static BOOL (*orig_wsOpenURL)(id, SEL, NSURL *) = NULL;

static BOOL swiz_wsOpenURL(id self, SEL _cmd, NSURL *url) {
    if (gInterceptMode) {
        gInterceptedURL = [url copy];
        return YES;
    }
    return orig_wsOpenURL(self, _cmd, url);
}

// ─── Augment a menu if it looks like a PictureView folder menu ───────────────

static void augmentMenuIfNeeded(NSMenu *menu, NSEvent *event, NSView *sourceView) {
    if (!menu || menu.itemArray.count == 0) return;

    BOOL hasFinder = NO;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:@"在访达中打开"]) { hasFinder = YES; break; }
    }
    NSLog(@"[PVTag] augment: items=%ld hasFinder=%d src=%@",
          (long)menu.itemArray.count, hasFinder, NSStringFromClass(sourceView.class));
    if (!hasFinder) return;

    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:@"标签"]) return;
    }

    // ── Resolve the target URL ────────────────────────────────────────────────
    NSURL *url = nil;

    NSURL *(^tryURL)(id) = ^NSURL *(id obj) {
        if (!obj || [obj isKindOfClass:[NSNull class]]) return nil;
        if ([obj isKindOfClass:[NSURL class]]) return obj;
        if ([obj respondsToSelector:@selector(url)]) {
            id r = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(url));
            if ([r isKindOfClass:[NSURL class]]) return r;
        }
        if ([obj respondsToSelector:@selector(path)]) {
            id r = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(path));
            if ([r isKindOfClass:[NSString class]] && [(NSString*)r length])
                return [NSURL fileURLWithPath:(NSString*)r];
        }
        return nil;
    };

    // Case 1: sidebar – sourceView or ancestor is NSTableView
    for (NSView *v = sourceView; v && !url; v = v.superview) {
        if (![v isKindOfClass:[NSTableView class]]) continue;
        NSTableView *tv = (NSTableView *)v;

        NSPoint pt    = [tv convertPoint:event.locationInWindow fromView:nil];
        NSInteger row = [tv rowAtPoint:pt];
        if (row < 0) row = tv.selectedRow;
        if (row < 0) break;

        for (id src in @[(id)tv.dataSource ?: [NSNull null], (id)tv.delegate ?: [NSNull null]]) {
            if ([src isKindOfClass:[NSNull class]]) continue;
            if ([src respondsToSelector:@selector(items)]) {
                id arr = ((id(*)(id,SEL))objc_msgSend)(src, @selector(items));
                if ([arr isKindOfClass:[NSArray class]] && row < (NSInteger)[(NSArray*)arr count]) {
                    id obj = [(NSArray*)arr objectAtIndex:row];
                    url = tryURL(obj);
                    if (!url && [obj respondsToSelector:@selector(item)])
                        url = tryURL(((id(*)(id,SEL))objc_msgSend)(obj, @selector(item)));
                }
            }
            if (!url && [src respondsToSelector:@selector(tableView:objectValueForTableColumn:row:)]) {
                id obj = [src tableView:tv objectValueForTableColumn:tv.tableColumns.firstObject row:row];
                url = tryURL(obj);
            }
            if (url) break;
        }

        // Also try the cell view's text + name cache
        if (!url) {
            NSView *cell = [tv viewAtColumn:0 row:row makeIfNecessary:NO];
            NSString *name = pvTextFromView(cell);
            url = pvURLFromName(name);
        }

        if (!url) {
            for (NSInteger col = 0; col < tv.tableColumns.count && !url; col++) {
                NSView *cell = [tv viewAtColumn:col row:row makeIfNecessary:NO];
                url = tryURL(cell);
                if (!url && cell) {
                    for (NSView *sv = cell.superview; sv && !url; sv = sv.superview)
                        url = tryURL(sv);
                }
            }
        }
        break;
    }

    // Case 2: Intercept the "在访达中打开" action to capture the URL
    if (!url) {
        NSMenuItem *finderItem = nil;
        for (NSMenuItem *mi in menu.itemArray) {
            if ([mi.title isEqualToString:@"在访达中打开"] && mi.target) {
                finderItem = mi; break;
            }
        }
        if (finderItem && [finderItem.target respondsToSelector:@selector(click:)]) {
            gInterceptMode  = YES;
            gInterceptedURL = nil;
            @try {
                ((void(*)(id,SEL,id))objc_msgSend)(finderItem.target, @selector(click:), finderItem);
            } @catch(NSException *e) {
                NSLog(@"[PVTag] click: intercept failed: %@", e);
            }
            gInterceptMode = NO;
            if (gInterceptedURL) {
                url = [NSURL fileURLWithPath:gInterceptedURL.path];
                NSLog(@"[PVTag] intercepted URL: %@", url);
            }
        }
    }

    NSLog(@"[PVTag] resolved url: %@ isFile=%d", url, url.isFileURL);
    if (!url || !url.isFileURL) return;

    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDir];
    if (!isDir) return;

    // Update caches
    cacheUpdate(url);
    NSString *name = url.lastPathComponent;
    if (name.length > 0) {
        @synchronized(gNameToURLCache) { gNameToURLCache[name] = url; }
    }

    // Associate URL with sourceView hierarchy (so drawRect: can find it for gallery cards)
    if (sourceView) {
        objc_setAssociatedObject(sourceView, &kURLAssocKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSView *v = sourceView; v; v = v.superview) {
            NSString *cls = NSStringFromClass(v.class);
            if ([cls containsString:@"GalleryPictureCard"] || [cls containsString:@"PictureCard"]) {
                objc_setAssociatedObject(v, &kURLAssocKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                break;
            }
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:makeTagMenuItem(url)];
    NSLog(@"[PVTag] tag dots injected for: %@", url.path);
}

// ─── Swizzle 1: NSView.menuForEvent: ─────────────────────────────────────────

static NSMenu *(*orig_menuForEvent)(NSView *, SEL, NSEvent *) = NULL;

static NSMenu *swiz_menuForEvent(NSView *self, SEL _cmd, NSEvent *event) {
    NSMenu *menu = orig_menuForEvent(self, _cmd, event);
    if (menu) augmentMenuIfNeeded(menu, event, self);
    return menu;
}

// ─── Swizzle 2: -[NSMenu popUpMenuPositioningItem:atLocation:inView:] ─────────

static BOOL (*orig_popUpPos)(NSMenu *, SEL, NSMenuItem *, NSPoint, NSView *) = NULL;

static BOOL swiz_popUpPos(NSMenu *self, SEL _cmd,
                          NSMenuItem *posItem, NSPoint loc, NSView *view) {
    NSView  *effectiveView  = view ?: gLastRightClickView;
    NSEvent *effectiveEvent = [NSApp currentEvent] ?: gLastRightClickEvent;
    augmentMenuIfNeeded(self, effectiveEvent, effectiveView);
    return orig_popUpPos(self, _cmd, posItem, loc, view);
}

// ─── Swizzle 3: +[NSMenu popUpContextMenu:withEvent:forView:] ────────────────

static void (*orig_popUp)(id, SEL, NSMenu *, NSEvent *, NSView *) = NULL;

static void swiz_popUp(id cls, SEL _cmd, NSMenu *menu, NSEvent *event, NSView *view) {
    augmentMenuIfNeeded(menu, event, view);
    orig_popUp(cls, _cmd, menu, event, view);
}

// ─── Swizzle 4: +[NSMenu popUpContextMenu:withEvent:forView:withFont:] ───────

static void (*orig_popUpFont)(id, SEL, NSMenu *, NSEvent *, NSView *, NSFont *) = NULL;

static void swiz_popUpFont(id cls, SEL _cmd, NSMenu *menu, NSEvent *event,
                            NSView *view, NSFont *font) {
    augmentMenuIfNeeded(menu, event, view);
    orig_popUpFont(cls, _cmd, menu, event, view, font);
}

// ─── Swizzle 5: NSView.rightMouseDown: ───────────────────────────────────────

static void (*orig_rightMouseDown)(NSView *, SEL, NSEvent *) = NULL;

static void swiz_rightMouseDown(NSView *self, SEL _cmd, NSEvent *event) {
    static NSTimeInterval lastTS = 0;
    if (event.timestamp != lastTS) {
        lastTS = event.timestamp;
        gLastRightClickView  = self;
        gLastRightClickEvent = event;
    }
    orig_rightMouseDown(self, _cmd, event);
}

// ─── Swizzle 6: NSView.drawRect: ─────────────────────────────────────────────
// For gallery card views: draw tag dots in bottom-left corner.
//
// URL resolution order:
//   1. objc_getAssociatedObject — set during right-click interception (instant)
//   2. pvTextFromView + gNameToURLCache — works after NSFileManager hook ran (pre-existing tags)
//
// The kURLTriedKey associated object prevents repeated discovery work per view instance.
// Note: NSTableView cell views ARE reused, so we rely on swiz_drawRow for sidebar —
// the kURLAssocKey on cell views is not used for sidebar dots.

static void (*orig_drawRect)(NSView *, SEL, NSRect) = NULL;

static void swiz_drawRect(NSView *self, SEL _cmd, NSRect rect) {
    orig_drawRect(self, _cmd, rect);

    // Fast path 1: URL already associated (right-click set it)
    NSURL *url = objc_getAssociatedObject(self, &kURLAssocKey);

    if (!url) {
        // Fast path 2: we already attempted discovery for this view
        if (objc_getAssociatedObject(self, &kURLTriedKey)) return;
        objc_setAssociatedObject(self, &kURLTriedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Only attempt discovery for gallery-style view classes
        NSString *cls = NSStringFromClass(self.class);
        if (![cls containsString:@"Gallery"] && ![cls containsString:@"Card"]) return;

        // Try name-based URL lookup from text subviews
        NSString *name = pvTextFromView(self);
        url = pvURLFromName(name);
        if (url) {
            objc_setAssociatedObject(self, &kURLAssocKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    if (!url) return;

    NSArray *tags = nil;
    @synchronized(gTagCache) { tags = gTagCache[url.path]; }
    if (!tags || tags.count == 0) return;

    // Draw tag dots in bottom-left corner of the card
    [NSGraphicsContext saveGraphicsState];
    pvDrawTagDots(tags, NSMakePoint(4.0, 4.0), 8.0);
    [NSGraphicsContext restoreGraphicsState];
}

// ─── Swizzle 8: NSFileManager.contentsOfDirectoryAtURL: ─────────────────────
// Pre-populate both caches for every directory listing PictureView requests.
// This ensures pre-existing Finder tags are visible without user interaction.

static NSArray *(*orig_contentsOfDir)(NSFileManager *, SEL, NSURL *, NSArray *,
                                      NSDirectoryEnumerationOptions, NSError **) = NULL;

static NSArray *swiz_contentsOfDir(NSFileManager *self, SEL _cmd, NSURL *url,
                                   NSArray *keys, NSDirectoryEnumerationOptions opts,
                                   NSError **err) {
    NSArray *results = orig_contentsOfDir(self, _cmd, url, keys, opts, err);

    NSArray *snapshot = [results copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL anyTagged = NO;
        for (NSURL *item in snapshot) {
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:item.path isDirectory:&isDir] || !isDir)
                continue;

            // Always cache name → URL so drawRow:/drawRect: can look up by text label
            NSString *name = item.lastPathComponent;
            if (name.length > 0) {
                @synchronized(gNameToURLCache) { gNameToURLCache[name] = item; }
            }

            // Cache tags if any
            NSArray *tags = currentTags(item);
            if (tags.count > 0) {
                @synchronized(gTagCache) { gTagCache[item.path] = tags; }
                anyTagged = YES;
            }
        }

        if (anyTagged) {
            // Inject/update tag dot subviews in all visible sidebar rows
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSWindow *win in NSApplication.sharedApplication.windows) {
                    pvRefreshTableTagDots(win.contentView);
                }
            });
        }
    });

    return results;
}

// ─── Entry point ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void PVTagPlugin_init(void) {
    gTagCache      = [NSMutableDictionary dictionary];
    gNameToURLCache = [NSMutableDictionary dictionary];

    // Self-test: verify xattr tag API works from our dylib
    {
        NSString *testDir = @"/tmp/pvtag_selftest";
        [[NSFileManager defaultManager] createDirectoryAtPath:testDir
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *testURL = [NSURL fileURLWithPath:testDir];
        writeRawTags(testURL, @[@"Red\n6"]);
        NSArray *readback = readRawTags(testURL);
        NSLog(@"[PVTag] self-test xattr: readback=%@", [readback componentsJoinedByString:@"|"]);
        writeRawTags(testURL, @[]); // clear
        [[NSFileManager defaultManager] removeItemAtPath:testDir error:nil];
    }

    // 1. NSView.menuForEvent:
    {
        Method m = class_getInstanceMethod([NSView class], @selector(menuForEvent:));
        if (m) {
            orig_menuForEvent = (NSMenu*(*)(NSView*,SEL,NSEvent*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_menuForEvent);
        }
    }

    // 2. -[NSMenu popUpMenuPositioningItem:atLocation:inView:]
    {
        Method m = class_getInstanceMethod([NSMenu class],
                       @selector(popUpMenuPositioningItem:atLocation:inView:));
        if (m) {
            orig_popUpPos = (BOOL(*)(NSMenu*,SEL,NSMenuItem*,NSPoint,NSView*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_popUpPos);
        }
    }

    // 3. +[NSMenu popUpContextMenu:withEvent:forView:]
    {
        Method m = class_getClassMethod([NSMenu class],
                       @selector(popUpContextMenu:withEvent:forView:));
        if (m) {
            orig_popUp = (void(*)(id,SEL,NSMenu*,NSEvent*,NSView*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_popUp);
        }
    }

    // 4. +[NSMenu popUpContextMenu:withEvent:forView:withFont:]
    {
        Method m = class_getClassMethod([NSMenu class],
                       @selector(popUpContextMenu:withEvent:forView:withFont:));
        if (m) {
            orig_popUpFont = (void(*)(id,SEL,NSMenu*,NSEvent*,NSView*,NSFont*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_popUpFont);
        }
    }

    // 5. NSView.rightMouseDown: — track which view was right-clicked
    {
        Method m = class_getInstanceMethod([NSView class], @selector(rightMouseDown:));
        if (m) {
            orig_rightMouseDown = (void(*)(NSView*,SEL,NSEvent*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_rightMouseDown);
        }
    }

    // 6. NSWorkspace URL interception hooks
    {
        Method m = class_getInstanceMethod([NSWorkspace class],
                       @selector(activateFileViewerSelectingURLs:));
        if (m) {
            orig_activateFileViewer = (void(*)(id,SEL,NSArray*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_activateFileViewer);
        }
    }
    {
        Method m = class_getInstanceMethod([NSWorkspace class], @selector(openURL:));
        if (m) {
            orig_wsOpenURL = (BOOL(*)(id,SEL,NSURL*))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_wsOpenURL);
        }
    }

    // 7. NSView.drawRect: — draw tag dots on gallery cards
    {
        Method m = class_getInstanceMethod([NSView class], @selector(drawRect:));
        if (m) {
            orig_drawRect = (void(*)(NSView*,SEL,NSRect))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_drawRect);
        }
    }

    // 8. NSFileManager.contentsOfDirectoryAtURL: — pre-populate caches
    {
        Method m = class_getInstanceMethod([NSFileManager class],
                       @selector(contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:));
        if (m) {
            orig_contentsOfDir = (NSArray*(*)(NSFileManager*,SEL,NSURL*,NSArray*,
                                              NSDirectoryEnumerationOptions,NSError**))
                                  method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_contentsOfDir);
        }
    }

    NSLog(@"[PVTag] loaded — 8 hooks installed");
}
