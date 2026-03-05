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

static NSArray<NSString *> *tagNames(void) {
    return @[@"Red", @"Orange", @"Yellow", @"Green", @"Blue", @"Purple", @"Gray"];
}

static NSArray<NSColor *> *tagColors(void) {
    return @[NSColor.systemRedColor, NSColor.systemOrangeColor, NSColor.systemYellowColor,
             NSColor.systemGreenColor, NSColor.systemBlueColor, NSColor.systemPurpleColor,
             NSColor.systemGrayColor];
}

// Finder color index for each standard tag name
static int tagColorIndex(NSString *name) {
    NSDictionary *m = @{@"Red":@6, @"Orange":@7, @"Yellow":@5,
                        @"Green":@2, @"Blue":@4, @"Purple":@3, @"Gray":@1};
    NSNumber *n = m[name];
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

// Write raw tag strings to xattr
static BOOL writeRawTags(NSURL *url, NSArray<NSString *> *rawTags) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:rawTags
                       format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return NO;
    const char *path = url.fileSystemRepresentation;
    return setxattr(path, FINDER_TAG_XATTR, data.bytes, data.length, 0, 0) == 0;
}

// Strip \nColorIndex suffix to get display name
static NSString *displayName(NSString *raw) {
    NSRange r = [raw rangeOfString:@"\n"];
    return r.location != NSNotFound ? [raw substringToIndex:r.location] : raw;
}

// Get display names of current tags (strips color index)
static NSArray<NSString *> *currentTags(NSURL *url) {
    NSArray *raw = readRawTags(url);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *s in raw) [names addObject:displayName(s)];
    return names;
}

// ─── Tag cache (path → display tag names) ────────────────────────────────────
// Populated by NSFileManager hook (pre-scans directories) and by toggleTag.
// Used by drawRow: and drawRect: to paint color dots without re-reading xattr.

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gTagCache;

// Associated object keys for attaching a file URL to a view
static const char kURLAssocKey  = 0;   // view → NSURL (its folder URL)
static const char kURLTriedKey  = 0;   // marker: we already tried to discover URL

// Update the cache entry for a single URL (call after any tag change)
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
    NSString *storedName = [NSString stringWithFormat:@"%@\n%d", tagName, tagColorIndex(tagName)];

    // Build updated list: remove if present, add if absent
    NSMutableArray *updated = [NSMutableArray array];
    BOOL found = NO;
    for (NSString *r in raw) {
        if ([displayName(r) isEqualToString:tagName]) { found = YES; continue; } // remove
        [updated addObject:r];
    }
    if (!found) [updated addObject:storedName]; // add

    BOOL ok = writeRawTags(url, updated);
    if (ok) cacheUpdate(url); // keep cache in sync
    NSLog(@"[PVTag] toggleTag '%@' %@ ok=%d → stored=%@",
          tagName, found ? @"removed" : @"added", ok,
          [updated componentsJoinedByString:@"|"]);
    return ok;
}

// ─── Drawing helpers ──────────────────────────────────────────────────────────

// Draw small colored circles (tag dots) starting at 'origin', diameter 'size'.
// Caller must set up/restore graphics state and NSColor if needed.
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

// ─── URL extraction from NSTableView data source ─────────────────────────────
// Returns the file URL for the model object at 'row' in the table, or nil.

static NSURL *urlFromTableViewRow(NSTableView *tv, NSInteger row) {
    if (row < 0) return nil;

    NSURL *(^tryURL)(id) = ^NSURL *(id obj) {
        if (!obj || [obj isKindOfClass:[NSNull class]]) return nil;
        if ([obj isKindOfClass:[NSURL class]]) return (NSURL *)obj;
        if ([obj respondsToSelector:@selector(url)]) {
            id r = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(url));
            if ([r isKindOfClass:[NSURL class]]) return (NSURL *)r;
        }
        if ([obj respondsToSelector:@selector(path)]) {
            id r = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(path));
            if ([r isKindOfClass:[NSString class]] && [(NSString *)r length])
                return [NSURL fileURLWithPath:(NSString *)r];
        }
        return nil;
    };

    for (id src in @[(id)tv.dataSource ?: [NSNull null], (id)tv.delegate ?: [NSNull null]]) {
        if ([src isKindOfClass:[NSNull class]]) continue;
        if ([src respondsToSelector:@selector(items)]) {
            id arr = ((id(*)(id,SEL))objc_msgSend)(src, @selector(items));
            if ([arr isKindOfClass:[NSArray class]] && row < (NSInteger)[(NSArray *)arr count]) {
                id obj = [(NSArray *)arr objectAtIndex:row];
                NSURL *u = tryURL(obj);
                if (!u && [obj respondsToSelector:@selector(item)])
                    u = tryURL(((id(*)(id,SEL))objc_msgSend)(obj, @selector(item)));
                if (u) return u;
            }
        }
        if ([src respondsToSelector:@selector(tableView:objectValueForTableColumn:row:)]) {
            id obj = [src tableView:tv objectValueForTableColumn:tv.tableColumns.firstObject row:row];
            NSURL *u = tryURL(obj);
            if (u) return u;
        }
    }
    return nil;
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

        // Filled circle
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:r];
        if (on || hover) {
            [c setFill];
        } else {
            [[c colorWithAlphaComponent:0.65] setFill];
        }
        [circle fill];

        // White checkmark for active tags
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

        // Subtle border on hover for inactive
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

        // Trigger redraw of the whole window so sidebar/gallery dots update
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSWindow *win in NSApplication.sharedApplication.windows) {
                pvMarkTableViewsNeedsDisplay(win.contentView);
                // Also mark any view that has an associated URL pointing to our path
                // (covers gallery cards)
                [win.contentView setNeedsDisplay:YES];
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
        return;  // don't actually open Finder
    }
    orig_activateFileViewer(self, _cmd, urls);
}

static BOOL (*orig_wsOpenURL)(id, SEL, NSURL *) = NULL;

static BOOL swiz_wsOpenURL(id self, SEL _cmd, NSURL *url) {
    if (gInterceptMode) {
        gInterceptedURL = [url copy];
        return YES;  // pretend success
    }
    return orig_wsOpenURL(self, _cmd, url);
}

// ─── Augment a menu if it looks like a PictureView folder menu ───────────────

static void augmentMenuIfNeeded(NSMenu *menu, NSEvent *event, NSView *sourceView) {
    if (!menu || menu.itemArray.count == 0) return;

    // Detect PictureView's folder context menus by looking for "在访达中打开"
    BOOL hasFinder = NO;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:@"在访达中打开"]) { hasFinder = YES; break; }
    }
    NSLog(@"[PVTag] augment: items=%ld hasFinder=%d src=%@",
          (long)menu.itemArray.count, hasFinder, NSStringFromClass(sourceView.class));
    if (!hasFinder) return;

    // Check we haven't already injected (guard against double calls)
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:@"标签"]) return;
    }

    // ── Resolve the target URL ────────────────────────────────────────────────
    NSURL *url = nil;

    // Helper: try to pull a file URL from an arbitrary object
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

        // Get the row under the right-click event
        NSPoint pt  = [tv convertPoint:event.locationInWindow fromView:nil];
        NSInteger row = [tv rowAtPoint:pt];
        if (row < 0) row = tv.selectedRow;
        if (row < 0) break;


        // Try data source and delegate for an 'items' array or objectValue
        for (id src in @[(id)tv.dataSource ?: [NSNull null], (id)tv.delegate ?: [NSNull null]]) {
            if ([src isKindOfClass:[NSNull class]]) continue;
            if ([src respondsToSelector:@selector(items)]) {
                id arr = ((id(*)(id,SEL))objc_msgSend)(src, @selector(items));
                if ([arr isKindOfClass:[NSArray class]] && row < (NSInteger)[(NSArray*)arr count]) {
                    id obj = [(NSArray*)arr objectAtIndex:row];
                    url = tryURL(obj);
                    // also try obj.item.url (for wrapped model objects)
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

        // Fallback: inspect the cell view in that row
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
                // Recreate from path to get a proper file URL for resource value ops
                url = [NSURL fileURLWithPath:gInterceptedURL.path];
                NSLog(@"[PVTag] intercepted URL: %@", url);
            }
        }
    }

    NSLog(@"[PVTag] resolved url: %@ isFile=%d", url, url.isFileURL);
    if (!url || !url.isFileURL) return;

    // Only tag directories
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDir];
    if (!isDir) return;

    // Update cache with current tags for this URL
    cacheUpdate(url);

    // Associate the URL with the source view so drawRect: can find it for the gallery card
    if (sourceView) {
        objc_setAssociatedObject(sourceView, &kURLAssocKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Also walk up to find GalleryPictureCard-like views and mark them
        for (NSView *v = sourceView; v; v = v.superview) {
            NSString *cls = NSStringFromClass(v.class);
            if ([cls containsString:@"GalleryPictureCard"] || [cls containsString:@"PictureCard"]) {
                objc_setAssociatedObject(v, &kURLAssocKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                break;
            }
        }
    }

    // ── Insert tag row ────────────────────────────────────────────────────────
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:makeTagMenuItem(url)];
    NSLog(@"[PVTag] tag dots injected for: %@", url.path);
}

// ─── Swizzle 1: NSView.menuForEvent: ─────────────────────────────────────────
// Called by AppKit right before showing a context menu; returns the NSMenu to display.

static NSMenu *(*orig_menuForEvent)(NSView *, SEL, NSEvent *) = NULL;

static NSMenu *swiz_menuForEvent(NSView *self, SEL _cmd, NSEvent *event) {
    NSMenu *menu = orig_menuForEvent(self, _cmd, event);
    if (menu) augmentMenuIfNeeded(menu, event, self);
    return menu;
}

// ─── Swizzle 2: -[NSMenu popUpMenuPositioningItem:atLocation:inView:] ─────────
// The most common programmatic popup path (menu.popUp(positioning:at:in:)).

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

// ─── Swizzle 5: NSTableView.drawRow:clipRect: ─────────────────────────────────
// After drawing each row, overlay tag color dots on the right side.

static void (*orig_drawRow)(NSTableView *, SEL, NSInteger, NSRect) = NULL;

static void swiz_drawRow(NSTableView *self, SEL _cmd, NSInteger row, NSRect clip) {
    orig_drawRow(self, _cmd, row, clip);

    // Get URL for this row (fast: indexed array access via data source)
    NSURL *url = urlFromTableViewRow(self, row);
    if (!url || !url.path.length) return;

    NSArray *tags = nil;
    @synchronized(gTagCache) { tags = gTagCache[url.path]; }
    if (!tags || tags.count == 0) return;

    // Draw dots right-aligned inside the row, vertically centered
    NSRect rowRect  = [self rectOfRow:row];
    CGFloat dotSize = 8.0;
    CGFloat spacing = 2.0;
    CGFloat margin  = 8.0;
    CGFloat totalW  = tags.count * dotSize + (tags.count - 1) * spacing;
    NSPoint origin  = NSMakePoint(NSMaxX(rowRect) - totalW - margin,
                                  NSMinY(rowRect) + (NSHeight(rowRect) - dotSize) / 2.0);

    [NSGraphicsContext saveGraphicsState];
    pvDrawTagDots(tags, origin, dotSize);
    [NSGraphicsContext restoreGraphicsState];
}

// ─── Swizzle 6: NSView.drawRect: ─────────────────────────────────────────────
// For gallery cards that have an associated URL, draw tag dots in bottom-left corner.

static void (*orig_drawRect)(NSView *, SEL, NSRect) = NULL;

static void swiz_drawRect(NSView *self, SEL _cmd, NSRect rect) {
    orig_drawRect(self, _cmd, rect);

    // Check for associated URL set during right-click interception
    id assoc = objc_getAssociatedObject(self, &kURLAssocKey);
    if (!assoc) return;  // fast path: no URL → nothing to draw
    if (![assoc isKindOfClass:[NSURL class]]) return;
    NSURL *url = (NSURL *)assoc;

    NSArray *tags = nil;
    @synchronized(gTagCache) { tags = gTagCache[url.path]; }
    if (!tags || tags.count == 0) return;

    // Draw small dots in bottom-left corner of the card view
    [NSGraphicsContext saveGraphicsState];
    CGFloat dotSize = 8.0;
    NSPoint origin  = NSMakePoint(4.0, 4.0);
    pvDrawTagDots(tags, origin, dotSize);
    [NSGraphicsContext restoreGraphicsState];
}

// ─── Swizzle 7: NSFileManager.contentsOfDirectoryAtURL:... ───────────────────
// Pre-populate gTagCache for every directory listing PictureView requests.

static NSArray *(*orig_contentsOfDir)(NSFileManager *, SEL, NSURL *, NSArray *,
                                      NSDirectoryEnumerationOptions, NSError **) = NULL;

static NSArray *swiz_contentsOfDir(NSFileManager *self, SEL _cmd, NSURL *url,
                                   NSArray *keys, NSDirectoryEnumerationOptions opts,
                                   NSError **err) {
    NSArray *results = orig_contentsOfDir(self, _cmd, url, keys, opts, err);

    // Background scan: cache tags for all subdirectory results
    NSArray *snapshot = [results copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL anyTagged = NO;
        for (NSURL *item in snapshot) {
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:item.path isDirectory:&isDir]) continue;
            if (!isDir) continue;
            NSArray *tags = currentTags(item);
            if (tags.count > 0) {
                @synchronized(gTagCache) { gTagCache[item.path] = tags; }
                anyTagged = YES;
            }
        }
        if (anyTagged) {
            // Refresh sidebar table views after cache is populated
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSWindow *win in NSApplication.sharedApplication.windows) {
                    pvMarkTableViewsNeedsDisplay(win.contentView);
                }
            });
        }
    });

    return results;
}

// ─── Entry point ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void PVTagPlugin_init(void) {
    gTagCache = [NSMutableDictionary dictionary];

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

    // 7. NSTableView.drawRow:clipRect: — draw tag dots in sidebar rows
    {
        Method m = class_getInstanceMethod([NSTableView class],
                       @selector(drawRow:clipRect:));
        if (m) {
            orig_drawRow = (void(*)(NSTableView*,SEL,NSInteger,NSRect))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_drawRow);
        }
    }

    // 8. NSView.drawRect: — draw tag dots on gallery cards (via associated URL)
    {
        Method m = class_getInstanceMethod([NSView class], @selector(drawRect:));
        if (m) {
            orig_drawRect = (void(*)(NSView*,SEL,NSRect))method_getImplementation(m);
            method_setImplementation(m, (IMP)swiz_drawRect);
        }
    }

    // 9. NSFileManager.contentsOfDirectoryAtURL: — pre-populate tag cache
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

    NSLog(@"[PVTag] loaded — %d hooks installed", 9);
}
