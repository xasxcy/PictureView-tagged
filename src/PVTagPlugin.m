// PVTagPlugin.m
// Injects Finder-style color-tag support into PictureView's context menus.
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
    NSLog(@"[PVTag] toggleTag '%@' %@ ok=%d → stored=%@",
          tagName, found ? @"removed" : @"added", ok,
          [updated componentsJoinedByString:@"|"]);
    return ok;
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

// ─── Entry point ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void PVTagPlugin_init(void) {
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
}
