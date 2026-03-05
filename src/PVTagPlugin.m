// PVTagPlugin.m
// Injects Finder color-tag support into PictureView's context menus.
//
// Strategy: swizzle NSMenu +popUpContextMenu:withEvent:forView:
// Every time PictureView shows a context menu that contains "在访达中打开",
// we append a "标签" submenu that reads/writes macOS Finder tags via NSURLTagNamesKey.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ─── Forward declarations ─────────────────────────────────────────────────────

static NSMenu  *buildTagSubmenu(NSURL *url);
static NSURL   *urlFromView(NSView *view, NSEvent *event);
static NSURL   *tryExtractURL(id obj);
static NSURL   *urlFromTableView(NSTableView *tv, NSEvent *event);

// ─── Finder tag helpers ───────────────────────────────────────────────────────

static NSArray<NSString *> *currentTags(NSURL *url) {
    NSArray *tags = nil;
    [url getResourceValue:&tags forKey:NSURLTagNamesKey error:nil];
    return tags ?: @[];
}

static void applyTag(NSURL *url, NSString *tagName) {
    NSMutableArray *tags = [currentTags(url) mutableCopy];
    if ([tags containsObject:tagName])
        [tags removeObject:tagName];      // toggle off
    else
        [tags addObject:tagName];         // toggle on
    [url setResourceValue:tags forKey:NSURLTagNamesKey error:nil];
}

static void clearAllTags(NSURL *url) {
    [url setResourceValue:@[] forKey:NSURLTagNamesKey error:nil];
}

// ─── Menu action handler ──────────────────────────────────────────────────────

@interface PVTagHandler : NSObject
+ (instancetype)shared;
- (void)tagAction:(NSMenuItem *)sender;
- (void)clearAction:(NSMenuItem *)sender;
@end

@implementation PVTagHandler

+ (instancetype)shared {
    static PVTagHandler *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [PVTagHandler new]; });
    return s;
}

- (void)tagAction:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    NSURL *url = info[@"url"];
    NSString *tag = info[@"tag"];
    if (url && tag) applyTag(url, tag);
}

- (void)clearAction:(NSMenuItem *)sender {
    NSURL *url = sender.representedObject;
    if (url) clearAllTags(url);
}

@end

// ─── Color dot image ──────────────────────────────────────────────────────────

static NSImage *dotImage(NSColor *color) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(14, 14)
                                  flipped:NO
                           drawingHandler:^BOOL(NSRect r) {
        NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        [c setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 1, 1)] fill];
        return YES;
    }];
    img.template = NO;
    return img;
}

// ─── Build tag submenu ────────────────────────────────────────────────────────

static NSMenu *buildTagSubmenu(NSURL *url) {
    static NSArray *names;
    static NSArray *labels;
    static NSArray *colors;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        names  = @[@"Red", @"Orange", @"Yellow", @"Green", @"Blue", @"Purple", @"Gray"];
        labels = @[@"红色", @"橙色", @"黄色", @"绿色", @"蓝色", @"紫色", @"灰色"];
        colors = @[NSColor.systemRedColor, NSColor.systemOrangeColor,
                   NSColor.systemYellowColor, NSColor.systemGreenColor,
                   NSColor.systemBlueColor, NSColor.systemPurpleColor,
                   NSColor.systemGrayColor];
    });

    NSArray *existing = currentTags(url);
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"标签"];

    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *name  = names[i];
        NSString *label = labels[i];
        NSColor  *color = colors[i];

        NSMenuItem *item = [[NSMenuItem alloc]
                            initWithTitle:label
                                   action:@selector(tagAction:)
                            keyEquivalent:@""];
        item.target = [PVTagHandler shared];
        item.representedObject = @{@"url": url, @"tag": name};
        item.image = dotImage(color);
        item.state = [existing containsObject:name]
                     ? NSControlStateValueOn
                     : NSControlStateValueOff;
        [sub addItem:item];
    }

    if (existing.count > 0) {
        [sub addItem:[NSMenuItem separatorItem]];
        NSMenuItem *clear = [[NSMenuItem alloc]
                             initWithTitle:@"清除标签"
                                    action:@selector(clearAction:)
                             keyEquivalent:@""];
        clear.target = [PVTagHandler shared];
        clear.representedObject = url;
        [sub addItem:clear];
    }

    return sub;
}

// ─── URL extraction ───────────────────────────────────────────────────────────

// Try to pull an NSURL out of an arbitrary object via common property names.
static NSURL *tryExtractURL(id obj) {
    if (!obj || [obj isKindOfClass:[NSNull class]]) return nil;

    if ([obj isKindOfClass:[NSURL class]])
        return (NSURL *)obj;

    // url property
    if ([obj respondsToSelector:@selector(url)]) {
        id r = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(url));
        if ([r isKindOfClass:[NSURL class]]) return r;
    }

    // path property -> NSURL
    if ([obj respondsToSelector:@selector(path)]) {
        id r = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(path));
        if ([r isKindOfClass:[NSString class]] && [(NSString*)r length] > 0)
            return [NSURL fileURLWithPath:r];
    }

    // item -> url (gallery cards have an 'item' property pointing to ImageRef)
    if ([obj respondsToSelector:@selector(item)]) {
        id inner = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(item));
        NSURL *u = tryExtractURL(inner);
        if (u) return u;
    }

    return nil;
}

// For the sidebar NSTableView: convert event location → row → model object → URL.
static NSURL *urlFromTableView(NSTableView *tv, NSEvent *event) {
    NSPoint pt  = [tv convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [tv rowAtPoint:pt];
    if (row < 0) row = tv.selectedRow;
    if (row < 0) return nil;

    // Try data source then delegate
    NSArray *sources = @[(id)tv.dataSource ?: [NSNull null],
                         (id)tv.delegate   ?: [NSNull null]];
    for (id src in sources) {
        if ([src isKindOfClass:[NSNull class]]) continue;

        // items array (PictureView stores items in an 'items' property)
        if ([src respondsToSelector:@selector(items)]) {
            id arr = ((id(*)(id,SEL))objc_msgSend)(src, @selector(items));
            if ([arr isKindOfClass:[NSArray class]] && row < [(NSArray*)arr count]) {
                NSURL *u = tryExtractURL([(NSArray*)arr objectAtIndex:row]);
                if (u) return u;
            }
        }

        // NSTableViewDataSource objectValue
        if ([src respondsToSelector:@selector(tableView:objectValueForTableColumn:row:)]) {
            NSTableColumn *col = tv.tableColumns.firstObject;
            id obj = [src tableView:tv objectValueForTableColumn:col row:row];
            NSURL *u = tryExtractURL(obj);
            if (u) return u;
        }
    }

    // Fallback: introspect the row view itself
    NSTableRowView *rowView = [tv rowViewAtRow:row makeIfNecessary:NO];
    if (rowView) {
        NSURL *u = tryExtractURL(rowView);
        if (u) return u;
        // walk cell views
        for (NSInteger col = 0; col < tv.tableColumns.count; col++) {
            NSView *cell = [tv viewAtColumn:col row:row makeIfNecessary:NO];
            u = tryExtractURL(cell);
            if (u) return u;
        }
    }

    return nil;
}

// Main URL resolution: handles both sidebar (NSTableView) and gallery (NSView subclass).
static NSURL *urlFromView(NSView *view, NSEvent *event) {
    // Walk up the hierarchy; first check if we hit a table view (sidebar case).
    for (NSView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[NSTableView class]]) {
            NSURL *u = urlFromTableView((NSTableView *)v, event);
            if (u) return u;
            break;
        }
    }

    // Gallery / card view case: walk hierarchy looking for any URL-bearing object.
    for (NSView *v = view; v; v = v.superview) {
        NSURL *u = tryExtractURL(v);
        if (u && u.isFileURL) return u;
    }

    return nil;
}

// ─── NSMenu swizzle ───────────────────────────────────────────────────────────

static IMP gOriginalPopUp = NULL;

static void augmentMenu(NSMenu *menu, NSEvent *event, NSView *view) {
    // Only act on menus that contain "在访达中打开".
    // Both the sidebar menu and the gallery subdirectory menu have this item.
    BOOL hasFinder = NO;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.title isEqualToString:@"在访达中打开"]) {
            hasFinder = YES;
            break;
        }
    }
    if (!hasFinder) return;

    // Resolve the URL for the right-clicked item.
    NSURL *url = urlFromView(view, event);
    if (!url || !url.isFileURL) return;

    // Check this is actually a directory (we only tag folders here).
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDir] || !isDir)
        return;

    // Append separator + "标签" submenu.
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *tagItem = [[NSMenuItem alloc]
                           initWithTitle:@"标签"
                                  action:nil
                           keyEquivalent:@""];
    tagItem.submenu = buildTagSubmenu(url);
    [menu addItem:tagItem];
}

// Replacement for +[NSMenu popUpContextMenu:withEvent:forView:]
static void swizzled_popUpContextMenu(id self, SEL _cmd,
                                      NSMenu *menu, NSEvent *event, NSView *view) {
    augmentMenu(menu, event, view);
    ((void(*)(id,SEL,NSMenu*,NSEvent*,NSView*))gOriginalPopUp)(self, _cmd, menu, event, view);
}

// ─── Entry point ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void PVTagPlugin_init(void) {
    // Swizzle the class method on NSMenu.
    // Class methods live on the metaclass.
    Class metaMenu = object_getClass([NSMenu class]);
    SEL  sel       = @selector(popUpContextMenu:withEvent:forView:);
    Method m       = class_getClassMethod([NSMenu class], sel);
    if (!m) return;

    gOriginalPopUp = method_getImplementation(m);
    method_setImplementation(m, (IMP)swizzled_popUpContextMenu);
}
