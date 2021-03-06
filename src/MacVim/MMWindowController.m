/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */
/*
 * MMWindowController
 *
 * Handles resizing of windows, acts as an mediator between MMVimView and
 * MMVimController.
 *
 * Resizing in windowed mode:
 *
 * In windowed mode resizing can occur either due to the window frame changing
 * size (e.g. when the user drags to resize), or due to Vim changing the number
 * of (rows,columns).  The former case is dealt with by letting the vim view
 * fill the entire content view when the window has resized.  In the latter
 * case we ensure that vim view fits on the screen.
 *
 * The vim view notifies Vim if the number of (rows,columns) does not match the
 * current number whenver the view size is about to change.  Upon receiving a
 * dimension change message, Vim notifies the window controller and the window
 * resizes.  However, the window is never resized programmatically during a
 * live resize (in order to avoid jittering).
 *
 * The window size is constrained to not become too small during live resize,
 * and it is also constrained to always fit an integer number of
 * (rows,columns).
 *
 * In windowed mode we have to manually draw a tabline separator (due to bugs
 * in the way Cocoa deals with the toolbar separator) when certain conditions
 * are met.  The rules for this are as follows:
 *
 *   Tabline visible & Toolbar visible  =>  Separator visible
 *   =====================================================================
 *         NO        &        NO        =>  YES, if the window is textured
 *                                           NO, otherwise
 *         NO        &       YES        =>  YES
 *        YES        &        NO        =>   NO
 *        YES        &       YES        =>   NO
 *
 *
 * Resizing in custom full-screen mode:
 *
 * The window never resizes since it fills the screen, however the vim view may
 * change size, e.g. when the user types ":set lines=60", or when a scrollbar
 * is toggled.
 *
 * It is ensured that the vim view never becomes larger than the screen size
 * and that it always stays in the center of the screen.
 *
 *
 * Resizing in native full-screen mode (Mac OS X 10.7+):
 *
 * The window is always kept centered and resizing works more or less the same
 * way as in windowed mode.
 *  
 */

#import "MMAppController.h"
#import "MMAtsuiTextView.h"
#import "MMFindReplaceController.h"
#import "MMFullScreenWindow.h"
#import "MMTextView.h"
#import "MMTypesetter.h"
#import "MMVimController.h"
#import "MMVimView.h"
#import "MMWindow.h"
#import "MMWindowController.h"
#import "MMFileBrowserController.h"
#import "Miscellaneous.h"
#import <PSMTabBarControl/PSMTabBarControl.h>
#import <Carbon/Carbon.h>

// These have to be the same as in option.h
#define FUOPT_MAXVERT         0x001
#define FUOPT_MAXHORZ         0x002
#define FUOPT_BGCOLOR_HLGROUP 0x004



@interface MMWindowController (Private)
- (NSSize)contentSize;
- (void)adjustWindowFrame;
- (void)resizeWindowToFitContentSize:(NSSize)contentSize
                        keepOnScreen:(BOOL)onScreen;
- (NSSize)constrainContentSizeToScreenSize:(NSSize)contentSize;
- (NSRect)constrainFrame:(NSRect)frame;
- (void)updateResizeConstraints;
- (NSTabViewItem *)addNewTabViewItem;
- (BOOL)askBackendForStarRegister:(NSPasteboard *)pb;
- (BOOL)hasTablineSeparator;
- (void)updateTablineSeparator;
- (void)hideTablineSeparator:(BOOL)hide;
- (void)doFindNext:(BOOL)next;
- (void)updateToolbar;
- (NSUInteger)representedIndexOfTabViewItem:(NSTabViewItem *)tvi;
- (void)enterCustomFullscreen;
- (void)leaveCustomFullscreen;
- (void)applicationDidChangeScreenParameters:(NSNotification *)notification;
- (BOOL)maximizeWindow:(int)options;
- (void)enterNativeFullScreen;
@end


@interface NSWindow (NSWindowPrivate)
// Note: This hack allows us to set content shadowing separately from
// the window shadow.  This is apparently what webkit and terminal do.
- (void)_setContentHasShadow:(BOOL)shadow; // new Tiger private method

// This is a private api that makes textured windows not have rounded corners.
// We want this on Leopard.
- (void)setBottomCornerRounded:(BOOL)rounded;
@end


@interface NSWindow (NSLeopardOnly)
// Note: These functions are Leopard-only, use -[NSObject respondsToSelector:]
// before calling them to make sure everything works on Tiger too.
- (void)setAutorecalculatesContentBorderThickness:(BOOL)b forEdge:(NSRectEdge)e;
- (void)setContentBorderThickness:(CGFloat)b forEdge:(NSRectEdge)e;
@end




@implementation MMWindowController

- (id)initWithVimController:(MMVimController *)controller
{
    unsigned styleMask = NSTitledWindowMask | NSClosableWindowMask
            | NSMiniaturizableWindowMask | NSResizableWindowMask
            | NSUnifiedTitleAndToolbarWindowMask;

    // Use textured background on Leopard or later (skip the 'if' on Tiger for
    // polished metal window).
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:MMTexturedWindowKey]
            || (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4))
        styleMask |= NSTexturedBackgroundWindowMask;

    // NOTE: The content rect is only used the very first time MacVim is
    // started (or rather, when ~/Library/Preferences/org.vim.MacVim.plist does
    // not exist).  The chosen values will put the window somewhere near the
    // top and in the middle of a 1024x768 screen.
    MMWindow *win = [[MMWindow alloc]
            initWithContentRect:NSMakeRect(242,364,480,360)
                      styleMask:styleMask
                        backing:NSBackingStoreBuffered
                          defer:YES];
    [win autorelease];

    self = [super initWithWindow:win];
    if (!self) return nil;

    vimController = controller;
    decoratedWindow = [win retain];

    // Window cascading is handled by MMAppController.
    [self setShouldCascadeWindows:NO];

    // NOTE: Autoresizing is enabled for the content view, but only used
    // for the tabline separator.  The vim view must be resized manually
    // because of full-screen considerations, and because its size depends
    // on whether the tabline separator is visible or not.
    NSView *contentView = [win contentView];
    NSRect frame = [contentView frame];
    [contentView setAutoresizesSubviews:YES];

    // Create the tab view (which is never visible, but the tab bar control
    // needs it to function).
    tabView = [[NSTabView alloc] initWithFrame:NSZeroRect];

    // Create the tab bar control (which is responsible for actually
    // drawing the tabline and tabs).
    NSRect tabFrame = { { 0, frame.size.height - 22 },
                        { frame.size.width, 22 } };
    tabBarControl = [[PSMTabBarControl alloc] initWithFrame:tabFrame];

    [tabView setDelegate:tabBarControl];

    [tabBarControl setTabView:tabView];
    [tabBarControl setDelegate:self];
    [tabBarControl setHidden:YES];

    [tabBarControl setCellMinWidth:[ud integerForKey:MMTabMinWidthKey]];
    [tabBarControl setCellMaxWidth:[ud integerForKey:MMTabMaxWidthKey]];
    [tabBarControl setCellOptimumWidth:
                                     [ud integerForKey:MMTabOptimumWidthKey]];

    [tabBarControl setShowAddTabButton:[ud boolForKey:MMShowAddTabButtonKey]];
    [[tabBarControl addTabButton] setTarget:self];
    [[tabBarControl addTabButton] setAction:@selector(addNewTab:)];
    [tabBarControl setAllowsDragBetweenWindows:NO];
    [tabBarControl registerForDraggedTypes:
                            [NSArray arrayWithObject:NSFilenamesPboardType]];

    [tabBarControl setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin];
    
    // Tab bar resizing only works if awakeFromNib is called (that's where the
    // NSViewFrameDidChangeNotification callback is installed). Sounds like a
    // PSMTabBarControl bug, let's live with it for now.
    [tabBarControl awakeFromNib];

    [contentView addSubview:tabBarControl];

    //frame.size.height -= 22;
    if (styleMask & NSTexturedBackgroundWindowMask)
        --frame.size.height;

    vimView = [[MMVimView alloc] initWithFrame:frame
                                 vimController:vimController];
    [vimView setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];

    // Avoid Vim view sending dimension change messages during startup.
    [vimView disableTextViewDimensionMessages:YES];

    splitView = [[NSSplitView alloc] initWithFrame:frame];
    [splitView setVertical:YES];
    [splitView setDividerStyle:NSSplitViewDividerStyleThin];
    [splitView setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
    [splitView setDelegate:self];

    //[tabBarControl setPartnerView:splitView];
    
#if 0
    NSRect tempFrame = frame;
    tempFrame.size.width = 150;
    NSImageView *view = [[NSImageView alloc] initWithFrame:tempFrame];
    [view setImage:[NSImage imageNamed:@"Attention"]];
    [view setImageFrameStyle:NSImageFrameGroove];
    [self setSidebarView:view leftEdge:NO];
#else
    [splitView addSubview:vimView];
    [splitView adjustSubviews];
#endif
    [contentView addSubview:splitView];

    [win setDelegate:self];
    [win setInitialFirstResponder:[vimView textView]];
    
    if ([win styleMask] & NSTexturedBackgroundWindowMask) {
        // On Leopard, we want to have a textured window to have nice
        // looking tabs. But the textured window look implies rounded
        // corners, which looks really weird -- disable them. This is a
        // private api, though.
        if ([win respondsToSelector:@selector(setBottomCornerRounded:)])
            [win setBottomCornerRounded:NO];

        // When the tab bar is toggled, it changes color for the fraction
        // of a second, probably because vim sends us events in a strange
        // order, confusing appkit's content border heuristic for a short
        // while.  This can be worked around with these two methods.  There
        // might be a better way, but it's good enough.
        if ([win respondsToSelector:@selector(
                setAutorecalculatesContentBorderThickness:forEdge:)])
            [win setAutorecalculatesContentBorderThickness:NO
                                                   forEdge:NSMaxYEdge];
        if ([win respondsToSelector:
                @selector(setContentBorderThickness:forEdge:)])
            [win setContentBorderThickness:0 forEdge:NSMaxYEdge];
    }

    // Make us safe on pre-tiger OSX
    if ([win respondsToSelector:@selector(_setContentHasShadow:)])
        [win _setContentHasShadow:NO];

    fileBrowserController = nil;
    if ([ud boolForKey:MMSidebarVisibleKey]) {
        [self openFileBrowser:nil];
        [win makeFirstResponder:[vimView textView]];
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(applicationDidChangeScreenParameters:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:NSApp];

#if (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7)
    [win setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
#endif

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    // Building on Mac OS X 10.7 or greater.

    // This puts the full-screen button in the top right of each window
    if ([win respondsToSelector:@selector(setCollectionBehavior:)])
        [win setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

    // This makes windows animate when opened
    if ([win respondsToSelector:@selector(setAnimationBehavior:)])
        [win setAnimationBehavior:NSWindowAnimationBehaviorDocumentWindow];
#endif

    [nc addObserver:self
           selector:@selector(applicationDidChangeScreenParameters:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:NSApp];

    return self;
}

- (void)dealloc
{
    ASLogDebug(@"");

    [fileBrowserController release];  fileBrowserController = nil;
    [decoratedWindow release];  decoratedWindow = nil;
    [windowAutosaveKey release];  windowAutosaveKey = nil;
    [vimView release];  vimView = nil;
    [sidebarView release];  sidebarView = nil;
    [splitView release];  splitView = nil;
    [tabBarControl release];  tabBarControl = nil;
    [tabView release];  tabView = nil;
    [toolbar release];  toolbar = nil;

    [super dealloc];
}

- (NSString *)description
{
    NSString *format =
        @"%@ : setupDone=%d windowAutosaveKey=%@ vimController=%@";
    return [NSString stringWithFormat:format,
        [self className], setupDone, windowAutosaveKey, vimController];
}

- (MMVimController *)vimController
{
    return vimController;
}

- (MMVimView *)vimView
{
    return vimView;
}

- (NSString *)windowAutosaveKey
{
    return windowAutosaveKey;
}

- (void)setWindowAutosaveKey:(NSString *)key
{
    [windowAutosaveKey autorelease];
    windowAutosaveKey = [key copy];
}

- (void)cleanup
{
    ASLogDebug(@"");

    // NOTE: Must set this before possibly leaving full-screen.
    setupDone = NO;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self];

    if (fullScreenEnabled) {
        // If we are closed while still in full-screen, end full-screen mode,
        // release ourselves (because this won't happen in MMWindowController)
        // and perform close operation on the original window.
        [self leaveFullScreen];
    }

    vimController = nil;

    // NOTE! There is a bug in PSMTabBarControl in that it retains the delegate
    // so reset the delegate here, otherwise the delegate may never get
    // released.
    [tabView setDelegate:nil];
    [tabBarControl setDelegate:nil];
    [tabBarControl setTabView:nil];

    // NOTE! There is another bug in PSMTabBarControl where the control is not
    // removed as an observer, so remove it here (failing to remove an observer
    // may lead to very strange bugs).
    [nc removeObserver:tabBarControl];

    [vimView cleanup];
    [fileBrowserController cleanup];

    // It is possible (though unlikely) that the user quits before the window
    // controller is released, make sure the edit flag is cleared so no warning
    // dialog is displayed.
    [decoratedWindow setDocumentEdited:NO];

    // NOTE! Calling orderOut: here will cause the views to set the 'needs
    // display' flag under certain conditions (such as clicking the close
    // button on a window).  Obviously having the views display themselves just
    // as the window is about to close is a bad idea, so clear this flag
    // immediately.  If we do not call orderOut: then the next window will not
    // get focus when a window is closed.
    [decoratedWindow orderOut:self];
    [decoratedWindow setViewsNeedDisplay:NO];
}

- (void)openWindow
{
    // Indicates that the window is ready to be displayed, but do not display
    // (or place) it yet -- that is done in showWindow.
    //
    // TODO: Remove this method?  Everything can probably be done in
    // presentWindow: but must carefully check dependencies on 'setupDone'
    // flag.

    [self addNewTabViewItem];

    setupDone = YES;
}

- (BOOL)presentWindow:(id)unused
{
    // If openWindow hasn't already been called then the window will be
    // displayed later.
    if (!setupDone) return NO;

    // Place the window now.  If there are multiple screens then a choice is
    // made as to which screen the window should be on.  This means that all
    // code that is executed before this point must not depend on the screen!

    [self adjustWindowFrame];
    [vimView disableTextViewDimensionMessages:NO];
    [[MMAppController sharedInstance] windowControllerWillOpen:self];
    [self updateResizeConstraints];
    //[self resizeWindowToFitContentSize:[vimView desiredSize]
    //                      keepOnScreen:YES];

    [decoratedWindow makeKeyAndOrderFront:self];

    // HACK! Calling makeKeyAndOrderFront: may cause Cocoa to force the window
    // into native full-screen mode (this happens e.g. if a new window is
    // opened when MacVim is already in full-screen).  In this case we don't
    // want the decorated window to pop up before the animation into
    // full-screen, so set its alpha to 0.
    if (fullScreenEnabled && !fullScreenWindow)
        [decoratedWindow setAlphaValue:0];

    // Flag that the window is now placed on screen.  From now on it is OK for
    // code to depend on the screen state.  (Such as constraining views etc.)
    windowPresented = YES;

    if (fullScreenWindow) {
        // Delayed entering of full-screen happens here (a ":set fu" in a
        // GUIEnter auto command could cause this).
        [self enterCustomFullscreen];
        fullScreenEnabled = YES;
    } else if (delayEnterFullScreen) {
        // Set alpha to zero so that the decorated window doesn't pop up
        // before we enter full-screen.
        [decoratedWindow setAlphaValue:0];
        [self enterNativeFullScreen];
    }

    return YES;
}

- (void)setTextDimensionsWithRows:(int)rows
                          columns:(int)cols
                           isLive:(BOOL)live
                          isReply:(BOOL)reply
{
    int maxRows, maxCols;
    [[vimView textView] getMaxRows:&maxRows columns:&maxCols];

    ASLogDebug(@"setTextDimensionsWithRows:%d columns:%d isLive:%d "
            "isReply:%d (rows=%d, cols=%d, setupDone=%d)",
            rows, cols, live, reply, maxRows, maxCols, setupDone);

    // NOTE: The only place where the (rows,columns) of the vim view are
    // modified is here and when entering/leaving full-screen.  Setting these
    // values have no immediate effect, the actual resizing of the view is done
    // in processInputQueueDidFinish.
    //
    // The 'live' flag indicates that this resize originated from a live
    // resize; it may very well happen that the view is no longer in live
    // resize when this message is received.  We refrain from changing the view
    // size when this flag is set, otherwise the window might jitter when the
    // user drags to resize the window.

    if (maxRows == rows && maxCols == cols)
        return;

    [vimView setDesiredRows:rows columns:cols];

    if (setupDone && !live) {
        shouldPlaceVimView = YES;
        shouldResizeWindow = !reply && !fullScreenWindow;
    }

    // Autosave rows and columns.
    if (windowAutosaveKey && !fullScreenEnabled && [tabBarControl isHidden]
            && rows > MMMinRows && cols > MMMinColumns) {
        // NOTE: Don't save if tabline is visible.  Otherwise new windows will
        // look like they are missing a line or two (depending on font size).
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setInteger:rows forKey:MMAutosaveRowsKey];
        [ud setInteger:cols forKey:MMAutosaveColumnsKey];
        [ud synchronize];
    }

    // Autosave rows and columns.
    if (windowAutosaveKey && !fullScreenEnabled
            && rows > MMMinRows && cols > MMMinColumns) {
        // HACK! If tabline is visible then window will look about one line
        // higher than it actually is so increment rows by one before
        // autosaving dimension so that the approximate total window height is
        // autosaved.  This is particularly important when window is maximized
        // vertically; if we don't add a row here a new window will appear to
        // not be tall enough when the first window is showing the tabline.
        // A negative side-effect of this is that the window will redraw on
        // startup if the window is too tall to fit on screen (which happens
        // for example if 'showtabline=2').
        // TODO: Store window pixel dimensions instead of rows/columns?
        int autosaveRows = rows;
        if (![tabBarControl isHidden])
            ++autosaveRows;

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setInteger:autosaveRows forKey:MMAutosaveRowsKey];
        [ud setInteger:cols forKey:MMAutosaveColumnsKey];
        [ud synchronize];
    }
}

- (void)zoomWithRows:(int)rows columns:(int)cols state:(int)state
{
    [self setTextDimensionsWithRows:rows
                            columns:cols
                             isLive:NO
                            isReply:NO];

    // NOTE: If state==0 then the window should be put in the non-zoomed
    // "user state".  That is, move the window back to the last stored
    // position.  If the window is in the zoomed state, the call to change the
    // dimensions above will also reposition the window to ensure it fits on
    // the screen.  However, since resizing of the window is delayed we also
    // delay repositioning so that both happen at the same time (this avoid
    // situations where the window woud appear to "jump").
    if (!state && !NSEqualPoints(NSZeroPoint, userTopLeft))
        shouldRestoreUserTopLeft = YES;
}

- (void)setTitle:(NSString *)title
{
    if (!title)
        return;

    [decoratedWindow setTitle:title];
    if (fullScreenWindow) {
        [fullScreenWindow setTitle:title];

        // NOTE: Cocoa does not update the "Window" menu for borderless windows
        // so we have to do it manually.
        [NSApp changeWindowsItem:fullScreenWindow title:title filename:NO];
    }
}

- (void)setDocumentFilename:(NSString *)filename
{
    if (!filename)
        return;

    // Ensure file really exists or the path to the proxy icon will look weird.
    // If the file does not exists, don't show a proxy icon.
    if (![[NSFileManager defaultManager] fileExistsAtPath:filename])
        filename = @"";

    [decoratedWindow setRepresentedFilename:filename];
    [fullScreenWindow setRepresentedFilename:filename];
}

- (void)setToolbar:(NSToolbar *)theToolbar
{
    if (theToolbar != toolbar) {
        [toolbar release];
        toolbar = [theToolbar retain];
    }

    // NOTE: Toolbar must be set here or it won't work to show it later.
    [decoratedWindow setToolbar:toolbar];

    // HACK! Redirect the pill button so that we can ask Vim to hide the
    // toolbar.
    NSButton *pillButton = [decoratedWindow
            standardWindowButton:NSWindowToolbarButton];
    if (pillButton) {
        [pillButton setAction:@selector(toggleToolbar:)];
        [pillButton setTarget:self];
    }
}

- (void)createScrollbarWithIdentifier:(int32_t)ident type:(int)type
{
    [vimView createScrollbarWithIdentifier:ident type:type];
}

- (BOOL)destroyScrollbarWithIdentifier:(int32_t)ident
{
    BOOL scrollbarHidden = [vimView destroyScrollbarWithIdentifier:ident];   
    shouldPlaceVimView = shouldPlaceVimView || scrollbarHidden;
    shouldMaximizeWindow = shouldMaximizeWindow || scrollbarHidden;

    return scrollbarHidden;
}

- (BOOL)showScrollbarWithIdentifier:(int32_t)ident state:(BOOL)visible
{
    BOOL scrollbarToggled = [vimView showScrollbarWithIdentifier:ident
                                                           state:visible];
    shouldPlaceVimView = shouldPlaceVimView || scrollbarToggled;
    shouldMaximizeWindow = shouldMaximizeWindow || scrollbarToggled;

    return scrollbarToggled;
}

- (void)setScrollbarPosition:(int)pos length:(int)len identifier:(int32_t)ident
{
    [vimView setScrollbarPosition:pos length:len identifier:ident];
}

- (void)setScrollbarThumbValue:(float)val proportion:(float)prop
                    identifier:(int32_t)ident
{
    [vimView setScrollbarThumbValue:val proportion:prop identifier:ident];
}

- (void)setDefaultColorsBackground:(NSColor *)back foreground:(NSColor *)fore
{
    // NOTE: This is called when the transparency changes so set the opacity
    // flag on the window here (should be faster if the window is opaque).
    BOOL isOpaque = [back alphaComponent] == 1.0f;
    [decoratedWindow setOpaque:isOpaque];
    if (fullScreenWindow)
        [fullScreenWindow setOpaque:isOpaque];

    [vimView setDefaultColorsBackground:back foreground:fore];
}

- (void)setFont:(NSFont *)font
{
    [[NSFontManager sharedFontManager] setSelectedFont:font isMultiple:NO];
    [[vimView textView] setFont:font];
    [self updateResizeConstraints];
    shouldMaximizeWindow = YES;
}

- (void)setWideFont:(NSFont *)font
{
    [[vimView textView] setWideFont:font];
}

- (void)processInputQueueDidFinish
{
    ASLogDebug(@"presented=%d  place view=%d  should resize=%d",
            windowPresented, shouldPlaceVimView, shouldResizeWindow);

    // NOTE: Resizing is delayed until after all commands have been processed
    // since it often happens that more than one command will cause a resize.
    // If we were to immediately resize then the vim view size would jitter
    // (e.g.  hiding/showing scrollbars often happens several time in one
    // update).
    // Also delay toggling the toolbar until after scrollbars otherwise
    // problems arise when showing toolbar and scrollbar at the same time, i.e.
    // on "set go+=rT".

    // Update toolbar before resizing, since showing the toolbar may require
    // the view size to become smaller.
    if (updateToolbarFlag != 0)
        [self updateToolbar];

#if 0
    // NOTE: If the window has not been presented then we must avoid resizing
    // the views since it will cause them to be constrained to the screen which
    // has not yet been set!
    if (windowPresented && shouldPlaceVimView) {
        shouldPlaceVimView = NO;

        // Make sure full-screen window stays maximized (e.g. when scrollbar or
        // tabline is hidden) according to 'fuopt'.

        BOOL didMaximize = NO;
        if (shouldMaximizeWindow && fullScreenEnabled &&
                (fullScreenOptions & (FUOPT_MAXVERT|FUOPT_MAXHORZ)) != 0)
            didMaximize = [self maximizeWindow:fullScreenOptions];

        shouldMaximizeWindow = NO;

        // Resize Vim view and window, but don't do this now if the window was
        // just reszied because this would make the window "jump" unpleasantly.
        // Instead wait for Vim to respond to the resize message and do the
        // resizing then.
        // TODO: What if the resize message fails to make it back?
        if (!didMaximize) {
            NSSize originalSize = [vimView frame].size;
            NSSize contentSize = [vimView desiredSize];
            contentSize = [self constrainContentSizeToScreenSize:contentSize];
            int rows = 0, cols = 0;
            contentSize = [vimView constrainRows:&rows columns:&cols
                                          toSize:contentSize];
            [vimView setFrameSize:contentSize];

            if (fullScreenWindow) {
                // NOTE! Don't mark the full-screen content view as needing an
                // update unless absolutely necessary since when it is updated
                // the entire screen is cleared.  This may cause some parts of
                // the Vim view to be cleared but not redrawn since Vim does
                // not realize that we've erased part of the view.
                if (!NSEqualSizes(originalSize, contentSize)) {
                    [[fullScreenWindow contentView] setNeedsDisplay:YES];
                    [fullScreenWindow centerView];
                }
            } else {
                [self resizeWindowToFitContentSize:contentSize
                                      keepOnScreen:keepOnScreen];
            }
        }
    }
#else
    if (windowPresented && shouldPlaceVimView) {
        if (fullScreenEnabled) {
            // This has the effect of disallowing dimension changes while in
            // full-screen mode.
            [vimView adjustTextViewDimensions];
        } else {
            if (shouldResizeWindow) {
                [self adjustWindowFrame];
                shouldResizeWindow = NO;
            }
        }

        [vimView placeViews];
        shouldPlaceVimView = NO;
    }

    // NOTE! Actual drawing must take place after window has been resized etc.,
    // else parts of the view will not draw properly after a resize.  (This
    // applies to the Core Text renderer only.)
    // See -[MMCoreTextView batchDrawNow] as to why we don't rely on the 'needs
    // resize' flag.
    [[vimView textView] batchDrawNow];
#endif
}

- (void)showTabBar:(BOOL)on
{
    [tabBarControl setHidden:!on];
    [self updateTablineSeparator];
    shouldMaximizeWindow = YES;
    shouldPlaceVimView = YES;

#if 1
    NSSize size;
    if (fullScreenWindow) {
        size = [[fullScreenWindow contentView] frame].size;
    } else {
        size = [[decoratedWindow contentView] frame].size;
        if ([self hasTablineSeparator])
            size.height -= 1;
    }

    if (on)
        size.height -= 22;

    if (!NSEqualSizes(size, [splitView frame].size)) {
        [splitView setFrameSize:size];
    }
#endif
}

- (void)showToolbar:(BOOL)on size:(int)size mode:(int)mode
{
    if (!toolbar) return;

    [toolbar setSizeMode:size];
    [toolbar setDisplayMode:mode];

    // Positive flag shows toolbar, negative hides it.
    updateToolbarFlag = on ? 1 : -1;

    // NOTE: If the window is not visible we must toggle the toolbar
    // immediately, otherwise "set go-=T" in .gvimrc will lead to the toolbar
    // showing its hide animation every time a new window is opened.  (See
    // processInputQueueDidFinish for the reason why we need to delay toggling
    // the toolbar when the window is visible.)
    if (![decoratedWindow isVisible])
        [self updateToolbar];
}

- (void)setMouseShape:(int)shape
{
    [[vimView textView] setMouseShape:shape];
}

- (void)adjustLinespace:(int)linespace
{
    if (vimView && [vimView textView]) {
        [[vimView textView] setLinespace:(float)linespace];
        shouldMaximizeWindow = shouldPlaceVimView = YES;
    }
}

- (void)liveResizeWillStart
{
    if (!setupDone) return;

    // Save the original title, if we haven't already.
    if (lastSetTitle == nil) {
        lastSetTitle = [[decoratedWindow title] retain];
    }

    // NOTE: During live resize Cocoa goes into "event tracking mode".  We have
    // to add the backend connection to this mode in order for resize messages
    // from Vim to reach MacVim.  We do not wish to always listen to requests
    // in event tracking mode since then MacVim could receive DO messages at
    // unexpected times (e.g. when a key equivalent is pressed and the menu bar
    // momentarily lights up).
    id proxy = [vimController backendProxy];
    NSConnection *connection = [(NSDistantObject*)proxy connectionForProxy];
    [connection addRequestMode:NSEventTrackingRunLoopMode];
}

- (void)liveResizeDidEnd
{
    if (!setupDone) return;

    // See comment above regarding event tracking mode.
    id proxy = [vimController backendProxy];
    NSConnection *connection = [(NSDistantObject*)proxy connectionForProxy];
    [connection removeRequestMode:NSEventTrackingRunLoopMode];

    // NOTE: During live resize messages from MacVim to Vim are often dropped
    // (because too many messages are sent at once).  This may lead to
    // inconsistent states between Vim and MacVim; to avoid this we send a
    // synchronous resize message to Vim now (this is not fool-proof, but it
    // does seem to work quite well).
    // Do NOT send a SetTextDimensionsMsgID message (as opposed to
    // LiveResizeMsgID) since then the view is constrained to not be larger
    // than the screen the window mostly occupies; this makes it impossible to
    // resize the window across multiple screens.

    int constrained[2];
    NSSize textViewSize = [[vimView textView] frame].size;
    [[vimView textView] constrainRows:&constrained[0] columns:&constrained[1]
                               toSize:textViewSize];

    ASLogDebug(@"End of live resize, notify Vim that text dimensions are %dx%d",
               constrained[1], constrained[0]);

    NSData *data = [NSData dataWithBytes:constrained length:2*sizeof(int)];
    BOOL sendOk = [vimController sendMessageNow:LiveResizeMsgID
                                           data:data
                                        timeout:.5];

    if (!sendOk) {
        // Sending of synchronous message failed.  Force the window size to
        // match the last dimensions received from Vim, otherwise we end up
        // with inconsistent states.
        //[self resizeWindowToFitContentSize:[vimView desiredSize]
        //                      keepOnScreen:NO];
        [self adjustWindowFrame];
    }

    // If we saved the original title while resizing, restore it.
    if (lastSetTitle != nil) {
        [decoratedWindow setTitle:lastSetTitle];
        [lastSetTitle release];
        lastSetTitle = nil;
    }
}

- (void)enterFullScreen:(int)fuoptions backgroundColor:(NSColor *)back
{
    if (fullScreenEnabled) return;

    BOOL useNativeFullScreen = [[NSUserDefaults standardUserDefaults]
                                            boolForKey:MMNativeFullScreenKey];
    // Make sure user is not trying to use native full-screen on systems that
    // do not support it.
    if (![NSWindow instancesRespondToSelector:@selector(toggleFullScreen:)])
        useNativeFullScreen = NO;

    fullScreenOptions = fuoptions;
    if (useNativeFullScreen) {
        // Enter native full-screen mode.  Only supported on Mac OS X 10.7+.
        if (windowPresented) {
            [self enterNativeFullScreen];
        } else {
            delayEnterFullScreen = YES;
        }
    } else {
        // Enter custom full-screen mode.  Always supported.
        ASLogInfo(@"Enter custom full-screen");

        // fullScreenWindow could be non-nil here if this is called multiple
        // times during startup.
        [fullScreenWindow release];

        fullScreenWindow = [[MMFullScreenWindow alloc]
            initWithWindow:decoratedWindow view:vimView backgroundColor:back];
        [fullScreenWindow setOptions:fuoptions];
        [fullScreenWindow setRepresentedFilename:
            [decoratedWindow representedFilename]];

        // NOTE: Do not enter full-screen until the window has been presented
        // since we don't actually know which screen to use before then.  (The
        // custom full-screen can appear on any screen, as opposed to native
        // full-screen which always uses the main screen.)
        if (windowPresented) {
            [self enterCustomFullscreen];
            fullScreenEnabled = YES;

            // The resize handle disappears so the vim view needs to update the
            // scrollbars.
            shouldPlaceVimView = YES;
        }
    }
}

- (void)leaveFullScreen
{
    if (!fullScreenEnabled) return;

    ASLogInfo(@"Exit full-screen");

    fullScreenEnabled = NO;
    if (fullScreenWindow) {
        // Using custom full-screen
        [self leaveCustomFullscreen];
        [fullScreenWindow release];
        fullScreenWindow = nil;

        // The vim view may be too large to fit the screen, so update it.
        shouldPlaceVimView = YES;
    } else {
        // Using native full-screen
        // NOTE: fullScreenEnabled is used to detect if we enter full-screen
        // programatically and so must be set before calling
        // realToggleFullScreen:.
        NSParameterAssert(fullScreenEnabled == NO);
        [decoratedWindow realToggleFullScreen:self];
    }
}

- (void)setFullScreenBackgroundColor:(NSColor *)back
{
    if (fullScreenWindow)
        [fullScreenWindow setBackgroundColor:back];
}

- (void)invFullScreen:(id)sender
{
    [vimController addVimInput:@"<C-\\><C-N>:set invfu<CR>"];
}

- (void)setBufferModified:(BOOL)mod
{
    // NOTE: We only set the document edited flag on the decorated window since
    // the custom full-screen window has no close button anyway.  (It also
    // saves us from keeping track of the flag in two different places.)
    [decoratedWindow setDocumentEdited:mod];
}

- (void)setTopLeft:(NSPoint)pt
{
    if (setupDone) {
        [decoratedWindow setFrameTopLeftPoint:pt];
    } else {
        // Window has not been "opened" yet (see openWindow:) but remember this
        // value to be used when the window opens.
        defaultTopLeft = pt;
    }
}

- (BOOL)getDefaultTopLeft:(NSPoint*)pt
{
    // A default top left point may be set in .[g]vimrc with the :winpos
    // command.  (If this has not been done the top left point will be the zero
    // point.)
    if (pt && !NSEqualPoints(defaultTopLeft, NSZeroPoint)) {
        *pt = defaultTopLeft;
        return YES;
    }

    return NO;
}

- (void)updateTabsWithData:(NSData *)data
{
    const void *p = [data bytes];
    const void *end = p + [data length];
    int tabIdx = 0;

    // HACK!  Current tab is first in the message.  This way it is not
    // necessary to guess which tab should be the selected one (this can be
    // problematic for instance when new tabs are created).
    int curtabIdx = *((int*)p);  p += sizeof(int);

    NSArray *tabViewItems = [tabBarControl representedTabViewItems];

    while (p < end) {
        NSTabViewItem *tvi = nil;

        //int wincount = *((int*)p);  p += sizeof(int);
        int infoCount = *((int*)p); p += sizeof(int);
        unsigned i;
        for (i = 0; i < infoCount; ++i) {
            int length = *((int*)p);  p += sizeof(int);
            if (length <= 0)
                continue;

            NSString *val = [[NSString alloc]
                    initWithBytes:(void*)p length:length
                         encoding:NSUTF8StringEncoding];
            p += length;

            switch (i) {
                case MMTabLabel:
                    // Set the label of the tab, adding a new tab when needed.
                    tvi = [tabView numberOfTabViewItems] <= tabIdx
                            ? [self addNewTabViewItem]
                            : [tabViewItems objectAtIndex:tabIdx];
                    [tvi setLabel:val];
                    ++tabIdx;
                    break;
                case MMTabToolTip:
                    if (tvi)
                        [tabBarControl setToolTip:val
                                          forTabViewItem:tvi];
                    break;
                default:
                    ASLogWarn(@"Unknown tab info for index: %d", i);
            }

            [val release];
        }
    }

    // Remove unused tabs from the NSTabView.  Note that when a tab is closed
    // the NSTabView will automatically select another tab, but we want Vim to
    // take care of which tab to select so set the vimTaskSelectedTab flag to
    // prevent the tab selection message to be passed on to the VimTask.
    vimTaskSelectedTab = YES;
    int i, count = [tabView numberOfTabViewItems];
    for (i = count-1; i >= tabIdx; --i) {
        id tvi = [tabViewItems objectAtIndex:i];
        [tabView removeTabViewItem:tvi];
    }
    vimTaskSelectedTab = NO;

    [self selectTabWithIndex:curtabIdx];
}

- (void)selectTabWithIndex:(int)idx
{
    NSArray *tabViewItems = [tabBarControl representedTabViewItems];
    if (idx < 0 || idx >= [tabViewItems count]) {
        ASLogWarn(@"No tab with index %d exists.", idx);
        return;
    }

    // Do not try to select a tab if already selected.
    NSTabViewItem *tvi = [tabViewItems objectAtIndex:idx];
    if (tvi != [tabView selectedTabViewItem]) {
        vimTaskSelectedTab = YES;
        [tabView selectTabViewItem:tvi];
        vimTaskSelectedTab = NO;
    }
}

- (void)collapseSidebar:(BOOL)on
{
    if (!sidebarView)
        return;

    if (on != [sidebarView isHidden]) {
        [sidebarView setHidden:on];
        [splitView adjustSubviews];
    }
}

- (BOOL)isSidebarCollapsed
{
    return !sidebarView || [sidebarView isHidden];
}

- (void)setSidebarView:(NSView *)view leftEdge:(BOOL)left
{
    NSArray *subviews = left
                      ? [NSArray arrayWithObjects:view, vimView, nil]
                      : [NSArray arrayWithObjects:vimView, view, nil];

    [sidebarView autorelease];
    sidebarView = [view retain];

    // Restore autosaved sidebar width
    CGFloat w = (CGFloat)[[NSUserDefaults standardUserDefaults]
                                            integerForKey:MMSidebarWidthKey];
    if (w < MMSidebarMinWidth)
        w = MMSidebarMinWidth;

    NSRect frame = [splitView frame];
    frame.size.width = w;
    [view setFrame:frame];

    [splitView setSubviews:subviews];
    [splitView adjustSubviews];

    // The resize indicator should always be enabled if the sidebar view is
    // rightmost.
    if (!left)
        [decoratedWindow setShowsResizeIndicator:YES];

    // Need to place views to make sure scrollbars are positioned properly now
    // that the view layout may have changed.
    shouldPlaceVimView = YES;
}


- (IBAction)addNewTab:(id)sender
{
    [vimController sendMessage:AddNewTabMsgID data:nil];
}

- (IBAction)toggleToolbar:(id)sender
{
    [vimController sendMessage:ToggleToolbarMsgID data:nil];
}

- (IBAction)performClose:(id)sender
{
    // NOTE: With the introduction of :macmenu it is possible to bind
    // File.Close to ":conf q" but at the same time have it send off the
    // performClose: action.  For this reason we no longer need the CloseMsgID
    // message.  However, we still need File.Close to send performClose:
    // otherwise Cmd-w will not work on dialogs.
    [self vimMenuItemAction:sender];
}

- (IBAction)findNext:(id)sender
{
    [self doFindNext:YES];
}

- (IBAction)findPrevious:(id)sender
{
    [self doFindNext:NO];
}

- (IBAction)vimMenuItemAction:(id)sender
{
    if (![sender isKindOfClass:[NSMenuItem class]]) return;

    // TODO: Make into category on NSMenuItem which returns descriptor.
    NSMenuItem *item = (NSMenuItem*)sender;
    NSMutableArray *desc = [NSMutableArray arrayWithObject:[item title]];

    NSMenu *menu = [item menu];
    while (menu) {
        [desc insertObject:[menu title] atIndex:0];
        menu = [menu supermenu];
    }

    // The "MainMenu" item is part of the Cocoa menu and should not be part of
    // the descriptor.
    if ([[desc objectAtIndex:0] isEqual:@"MainMenu"])
        [desc removeObjectAtIndex:0];

    NSDictionary *attrs = [NSDictionary dictionaryWithObject:desc
                                                      forKey:@"descriptor"];
    [vimController sendMessage:ExecuteMenuMsgID data:[attrs dictionaryAsData]];
}

- (IBAction)vimToolbarItemAction:(id)sender
{
    NSArray *desc = [NSArray arrayWithObjects:@"ToolBar", [sender label], nil];
    NSDictionary *attrs = [NSDictionary dictionaryWithObject:desc
                                                      forKey:@"descriptor"];
    [vimController sendMessage:ExecuteMenuMsgID data:[attrs dictionaryAsData]];
}

- (IBAction)fontSizeUp:(id)sender
{
    [[NSFontManager sharedFontManager] modifyFont:
            [NSNumber numberWithInt:NSSizeUpFontAction]];
}

- (IBAction)fontSizeDown:(id)sender
{
    [[NSFontManager sharedFontManager] modifyFont:
            [NSNumber numberWithInt:NSSizeDownFontAction]];
}

- (IBAction)findAndReplace:(id)sender
{
    int tag = [sender tag];
    MMFindReplaceController *fr = [MMFindReplaceController sharedInstance];
    int flags = 0;

    // NOTE: The 'flags' values must match the FRD_ defines in gui.h (except
    // for 0x100 which we use to indicate a backward search).
    switch (tag) {
        case 1: flags = 0x100; break;
        case 2: flags = 3; break;
        case 3: flags = 4; break;
    }

    if ([fr matchWord])
        flags |= 0x08;
    if (![fr ignoreCase])
        flags |= 0x10;

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
            [fr findString],                @"find",
            [fr replaceString],             @"replace",
            [NSNumber numberWithInt:flags], @"flags",
            nil];

    [vimController sendMessage:FindReplaceMsgID data:[args dictionaryAsData]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(vimMenuItemAction:)
            || [item action] == @selector(performClose:))
        return [item tag];

    return YES;
}

// -- NSWindow delegate ------------------------------------------------------

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    if (fullScreenWindow) {
        // Hide menu and dock, both appear on demand.
        //
        // Another way to deal with several full-screen windows would be to
        // hide/reveal the dock only when the first full-screen window is
        // created and show it again after the last one has been closed, but
        // toggling on each focus gain/loss works better with Spaces. The
        // downside is that the menu bar flashes shortly when switching between
        // two full-screen windows.

        // XXX: If you have a full-screen window on a secondary monitor and
        // unplug the monitor, this will probably not work right.

        if ([fullScreenWindow isOnPrimaryScreen])
            SetSystemUIMode(kUIModeAllSuppressed, 0); //requires 10.3
    }

    [[MMAppController sharedInstance] setMainMenu:[vimController mainMenu]];
    [vimController sendMessage:GotFocusMsgID data:nil];

    if ([vimView textView]) {
        NSFontManager *fm = [NSFontManager sharedFontManager];
        [fm setSelectedFont:[[vimView textView] font] isMultiple:NO];
    }
}

- (void)windowDidResignMain:(NSNotification *)notification
{
    if (fullScreenWindow) {
        // Order menu and dock back in
        if ([fullScreenWindow isOnPrimaryScreen])
            SetSystemUIMode(kUIModeNormal, 0);
    }

    [vimController sendMessage:LostFocusMsgID data:nil];
}

- (BOOL)windowShouldClose:(id)sender
{
    // Don't close the window now; Instead let Vim decide whether to close the
    // window or not.
    [vimController sendMessage:VimShouldCloseMsgID data:nil];
    return NO;
}

- (void)windowDidMove:(NSNotification *)notification
{
    if (!setupDone)
        return;

    if (fullScreenWindow) {
        // Window may move as a result of being dragged between Spaces.
        ASLogDebug(@"Full-screen window moved, "
                "ensuring it covers the screen...");

        // The full-screen window may have moved to/off the screen with the
        // menu bar, so we hide/show the menu bar as a precaution.
        if ([fullScreenWindow isOnPrimaryScreen])
            SetSystemUIMode(kUIModeAllSuppressed, 0);
        else
            SetSystemUIMode(kUIModeNormal, 0);

        [fullScreenWindow setFrame:[[fullScreenWindow screen] frame]
                           display:NO];
    } else if (fullScreenEnabled) {
        // NOTE: The full-screen is not supposed to be able to be moved.  If we
        // do get here while in full-screen something unexpected happened (e.g.
        // the full-screen window was on an external display that got
        // unplugged).
        return;
    } else {
        NSRect frame = [decoratedWindow frame];
        NSPoint topLeft = { frame.origin.x, NSMaxY(frame) };
        if (windowAutosaveKey) {
            NSString *topLeftString = NSStringFromPoint(topLeft);

            [[NSUserDefaults standardUserDefaults]
                setObject:topLeftString forKey:windowAutosaveKey];
        }

        // NOTE: This method is called when the user drags the window, but not
        // when the top left point changes programmatically.
        // NOTE 2: Vim counts Y-coordinates from the top of the screen.
        int pos[2] = {
                (int)topLeft.x,
                (int)(NSMaxY([[decoratedWindow screen] frame]) - topLeft.y) };
        NSData *data = [NSData dataWithBytes:pos length:2*sizeof(int)];
        [vimController sendMessage:SetWindowPositionMsgID data:data];
    }
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window
                        defaultFrame:(NSRect)newFrame
{
    // Decide whether too zoom horizontally or not (always zoom vertically).
    NSEvent *event = [NSApp currentEvent];
    BOOL cmdLeftClick = [event type] == NSLeftMouseUp &&
                        [event modifierFlags] & NSCommandKeyMask;
    BOOL zoomBoth = [[NSUserDefaults standardUserDefaults]
                                                    boolForKey:MMZoomBothKey];
    zoomBoth = (zoomBoth && !cmdLeftClick) || (!zoomBoth && cmdLeftClick);

    if (!zoomBoth) {
        // Only zoom vertically.
        NSRect frame = [window frame];
        newFrame.origin.x = frame.origin.x;
        newFrame.size.width = frame.size.width;
    }

    return newFrame;
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification
{
    [vimController sendMessage:BackingPropertiesChangedMsgID data:nil];
}

// This is not an NSWindow delegate method, our custom MMWindow class calls it
// instead of the usual windowWillUseStandardFrame:defaultFrame:.
- (IBAction)zoom:(id)sender
{
    NSScreen *screen = [decoratedWindow screen];
    if (!screen) {
        ASLogNotice(@"Window not on screen, zoom to main screen");
        screen = [NSScreen mainScreen];
        if (!screen) {
            ASLogNotice(@"No main screen, abort zoom");
            return;
        }
    }

    // Decide whether too zoom horizontally or not (always zoom vertically).
    NSEvent *event = [NSApp currentEvent];
    BOOL cmdLeftClick = [event type] == NSLeftMouseUp &&
                        [event modifierFlags] & NSCommandKeyMask;
    BOOL zoomBoth = [[NSUserDefaults standardUserDefaults]
                                                    boolForKey:MMZoomBothKey];
    zoomBoth = (zoomBoth && !cmdLeftClick) || (!zoomBoth && cmdLeftClick);

    // Figure out how many rows/columns can fit while zoomed.
    int rowsZoomed, colsZoomed;
    NSRect maxFrame = [screen visibleFrame];
    NSRect contentRect = [decoratedWindow contentRectForFrameRect:maxFrame];
    [vimView constrainRows:&rowsZoomed
                   columns:&colsZoomed
                    toSize:contentRect.size];

    int curRows, curCols;
    [[vimView textView] getMaxRows:&curRows columns:&curCols];

    int rows, cols;
    BOOL isZoomed = zoomBoth ? curRows >= rowsZoomed && curCols >= colsZoomed
                             : curRows >= rowsZoomed;
    if (isZoomed) {
        rows = userRows > 0 ? userRows : curRows;
        cols = userCols > 0 ? userCols : curCols;
    } else {
        rows = rowsZoomed;
        cols = zoomBoth ? colsZoomed : curCols;

        if (curRows+2 < rows || curCols+2 < cols) {
            // The window is being zoomed so save the current "user state".
            // Note that if the window does not enlarge by a 'significant'
            // number of rows/columns then we don't save the current state.
            // This is done to take into account toolbar/scrollbars
            // showing/hiding.
            userRows = curRows;
            userCols = curCols;
            NSRect frame = [decoratedWindow frame];
            userTopLeft = NSMakePoint(frame.origin.x, NSMaxY(frame));
        }
    }

    // NOTE: Instead of resizing the window immediately we send a zoom message
    // to the backend so that it gets a chance to resize before the window
    // does.  This avoids problems with the window flickering when zooming.
    int info[3] = { rows, cols, !isZoomed };
    NSData *data = [NSData dataWithBytes:info length:3*sizeof(int)];
    [vimController sendMessage:ZoomMsgID data:data];
}

- (IBAction)openFileBrowser:(id)sender
{
    if (fileBrowserController == nil) {
      fileBrowserController = [[MMFileBrowserController alloc]
                                            initWithWindowController:self];
      NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
      [self setSidebarView:fileBrowserController.view
                  leftEdge:[ud boolForKey:MMSidebarOnLeftEdgeKey]];
      [fileBrowserController setNextKeyView:[vimView textView]];
    }
    [self collapseSidebar:NO];
    [fileBrowserController makeFirstResponder:self];
}

- (IBAction)closeFileBrowser:(id)sender
{
    [self collapseSidebar:YES];
}

- (IBAction)toggleFileBrowser:(id)sender
{
    if ([self isSidebarCollapsed])
        [self openFileBrowser:sender];
    else
        [self closeFileBrowser:sender];
}

- (IBAction)selectInFileBrowser:(id)sender
{
    [fileBrowserController selectInBrowser];
}

- (IBAction)revealInFileBrowser:(id)sender
{
    [fileBrowserController selectInBrowserByExpandingItems];
}

- (IBAction)sidebarEdgePreferenceChanged:(id)sender
{
    if (!sidebarView || [[splitView subviews] count] != 2)
        return;

    BOOL leftEdge = [[NSUserDefaults standardUserDefaults]
                                            boolForKey:MMSidebarOnLeftEdgeKey];
    [self setSidebarView:sidebarView leftEdge:leftEdge];
    //[vimView placeViews];
    [vimController sendMessage:ForceRedrawMsgID data:nil];
}

// -- Services menu delegate -------------------------------------------------

- (id)validRequestorForSendType:(NSString *)sendType
                     returnType:(NSString *)returnType
{
    if ([sendType isEqual:NSStringPboardType]
            && [self askBackendForStarRegister:nil])
        return self;

    return [super validRequestorForSendType:sendType returnType:returnType];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
                             types:(NSArray *)types
{
    if (![types containsObject:NSStringPboardType])
        return NO;

    return [self askBackendForStarRegister:pboard];
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
    // Replace the current selection with the text on the pasteboard.
    NSArray *types = [pboard types];
    if ([types containsObject:NSStringPboardType]) {
        NSString *input = [NSString stringWithFormat:@"s%@",
                 [pboard stringForType:NSStringPboardType]];
        [vimController addVimInput:input];
        return YES;
    }

    return NO;
}


// -- Split view delegate ----------------------------------------------------

// NOTE: A general assumption in these delegate messages is that there is a
// main view (the Vim view) and a side view, and that the split is vertical.
// If more views are added to the split view or if the split is changed to
// horizontal then these delegate methods need to be updated.

#if 0
- (void)splitView:(NSSplitView *)sv resizeSubviewsWithOldSize:(NSSize)oldSize
{
    // This code assumes that there are at most two views in a vertical split
    // arrangement.  Horizontal space changes are accumulated into the vimView,
    // the other view has a fixed width.

    NSSize size = [splitView frame].size;

    if (sidebarView && ![sidebarView isHidden]) {
        CGFloat d = size.width - oldSize.width;
        NSSize vsize = [vimView frame].size;
        NSSize ssize = [sidebarView frame].size;

        vsize.width += d;
        vsize.height = ssize.height = size.height;

        [vimView setFrameSize:vsize];
        [sidebarView setFrameSize:ssize];
    } else {
        [vimView setFrameSize:size];
    }
}

#else

- (BOOL)splitView:(NSSplitView *)sv shouldAdjustSizeOfSubview:(NSView *)subview
{
    // Only the Vim view should resize when the split view changes size.
    return subview == vimView;
}

#endif

- (BOOL)splitView:(NSSplitView *)splitView
    shouldHideDividerAtIndex:(NSInteger)dividerIndex
{
    // This ensures that the divider hides when the side view is collapsed.
    return [self isSidebarCollapsed];
}

- (BOOL)splitView:(NSSplitView *)sv canCollapseSubview:(NSView *)subview
{
    // Only the side view can collapse
    return sidebarView && subview == sidebarView;
}

- (BOOL)splitView:(NSSplitView *)sv
                shouldCollapseSubview:(NSView *)subview
       forDoubleClickOnDividerAtIndex:(NSInteger)idx
{
    // Only the side view can collapse
    return sidebarView && subview == sidebarView;
}

- (CGFloat)splitView:(NSSplitView *)sv
        constrainMinCoordinate:(CGFloat)proposedMin
                   ofSubviewAt:(NSInteger)idx
{
    // Constrain Vim size minimum size when on the left.  Note that this only
    // applies when dragging the divider.

    NSArray *views = [splitView subviews];
    if ([views count] < 1)
        return proposedMin;

    return ([views objectAtIndex:0] == vimView) ? [vimView minSize].width
                                                : proposedMin;
}

- (CGFloat)splitView:(NSSplitView *)sv
        constrainMaxCoordinate:(CGFloat)proposedMax
                   ofSubviewAt:(NSInteger)idx
{
    // Constrain Vim size minimum size when on the right.  Note that this only
    // applies when dragging the divider.

    NSArray *views = [splitView subviews];
    if ([views count] < 2)
        return proposedMax;

    return [views objectAtIndex:1] == vimView
                    ? [splitView frame].size.width - [vimView minSize].width
                    : proposedMax;
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
    if (windowAutosaveKey && ![self isSidebarCollapsed]) {
        // Autosave the width of the sidebar
        NSInteger w = (NSInteger)[sidebarView frame].size.width;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setInteger:w forKey:MMSidebarWidthKey];
        [ud synchronize];
    }
}


// -- PSMTabBarControl delegate ----------------------------------------------


- (BOOL)tabView:(NSTabView *)theTabView shouldSelectTabViewItem:
    (NSTabViewItem *)tabViewItem
{
    // NOTE: It would be reasonable to think that 'shouldSelect...' implies
    // that this message only gets sent when the user clicks the tab.
    // Unfortunately it is not so, which is why we need the
    // 'vimTaskSelectedTab' flag.
    //
    // HACK!  The selection message should not be propagated to Vim if Vim
    // selected the tab (e.g. as opposed the user clicking the tab).  The
    // delegate method has no way of knowing who initiated the selection so a
    // flag is set when Vim initiated the selection.
    if (!vimTaskSelectedTab) {
        // Propagate the selection message to Vim.
        NSUInteger idx = [self representedIndexOfTabViewItem:tabViewItem];
        if (NSNotFound != idx) {
            int i = (int)idx;   // HACK! Never more than MAXINT tabs?!
            NSData *data = [NSData dataWithBytes:&i length:sizeof(int)];
            [vimController sendMessage:SelectTabMsgID data:data];
        }
    }

    // Unless Vim selected the tab, return NO, and let Vim decide if the tab
    // should get selected or not.
    return vimTaskSelectedTab;
}

- (BOOL)tabView:(NSTabView *)theTabView shouldCloseTabViewItem:
        (NSTabViewItem *)tabViewItem
{
    // HACK!  This method is only called when the user clicks the close button
    // on the tab.  Instead of letting the tab bar close the tab, we return NO
    // and pass a message on to Vim to let it handle the closing.
    NSUInteger idx = [self representedIndexOfTabViewItem:tabViewItem];
    int i = (int)idx;   // HACK! Never more than MAXINT tabs?!
    NSData *data = [NSData dataWithBytes:&i length:sizeof(int)];
    [vimController sendMessage:CloseTabMsgID data:data];

    return NO;
}

- (void)tabView:(NSTabView *)theTabView didDragTabViewItem:
        (NSTabViewItem *)tabViewItem toIndex:(int)idx
{
    NSMutableData *data = [NSMutableData data];
    [data appendBytes:&idx length:sizeof(int)];

    [vimController sendMessage:DraggedTabMsgID data:data];
}

- (NSDragOperation)tabBarControl:(PSMTabBarControl *)theTabBarControl
        draggingEntered:(id <NSDraggingInfo>)sender
        forTabAtIndex:(NSUInteger)tabIndex
{
    NSPasteboard *pb = [sender draggingPasteboard];
    return [[pb types] containsObject:NSFilenamesPboardType]
            ? NSDragOperationCopy
            : NSDragOperationNone;
}

- (BOOL)tabBarControl:(PSMTabBarControl *)theTabBarControl
        performDragOperation:(id <NSDraggingInfo>)sender
        forTabAtIndex:(NSUInteger)tabIndex
{
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([[pb types] containsObject:NSFilenamesPboardType]) {
        NSArray *filenames = [pb propertyListForType:NSFilenamesPboardType];
        if ([filenames count] == 0)
            return NO;
        if (tabIndex != NSNotFound) {
            // If dropping on a specific tab, only open one file
            [vimController file:[filenames objectAtIndex:0]
                draggedToTabAtIndex:tabIndex];
        } else {
            // Files were dropped on empty part of tab bar; open them all
            [vimController filesDraggedToTabBar:filenames];
        }
        return YES;
    } else {
        return NO;
    }
}


#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)

// -- Full-screen delegate ---------------------------------------------------

- (NSApplicationPresentationOptions)window:(NSWindow *)window
    willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)opt
{
    return opt | NSApplicationPresentationAutoHideToolbar;
}

- (NSArray *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window
{
    return [NSArray arrayWithObject:decoratedWindow];
}

- (void)window:(NSWindow *)window
    startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration
{
    // Fade out window, remove title bar and maximize, then fade back in.
    // (There is a small delay before window is maximized but usually this is
    // not noticeable on a relatively modern Mac.)
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:0.5*duration];
        [[window animator] setAlphaValue:0];
    } completionHandler:^{
        [window setStyleMask:([window styleMask] | NSFullScreenWindowMask)];
        [tabBarControl setStyleNamed:@"Unified"];
        [self updateTablineSeparator];
        [self maximizeWindow:fullScreenOptions];

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            [context setDuration:0.5*duration];
            [[window animator] setAlphaValue:1];
        } completionHandler:^{
            // Do nothing
        }];
    }];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    // Store window frame and use it when exiting full-screen.
    preFullScreenFrame = [decoratedWindow frame];

    // ASSUMPTION: fullScreenEnabled always reflects the state of Vim's 'fu'.
    if (!fullScreenEnabled) {
        ASLogDebug(@"Full-screen out of sync, tell Vim to set 'fu'");
        // NOTE: If we get here it means that Cocoa has somehow entered
        // full-screen without us getting to set the 'fu' option first, so Vim
        // and the GUI are out of sync.  The following code (eventually) gets
        // them back into sync.  A problem is that the full-screen options have
        // not been set, so we have to cache that state and grab it here.
        fullScreenOptions = [[vimController objectForVimStateKey:
                                            @"fullScreenOptions"] intValue];
        fullScreenEnabled = YES;
        [self invFullScreen:self];
    }
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window
{
    // NOTE: This message can be called without
    // window:startCustomAnimationToEnterFullScreenWithDuration: ever having
    // been called so any state to store before entering full-screen must be
    // stored in windowWillEnterFullScreen: which always gets called.
    ASLogNotice(@"Failed to ENTER full-screen, restoring window frame...");

    fullScreenEnabled = NO;
    [window setAlphaValue:1];
    [window setStyleMask:([window styleMask] & ~NSFullScreenWindowMask)];
    [tabBarControl setStyleNamed:@"Metal"];
    [self updateTablineSeparator];
    [window setFrame:preFullScreenFrame display:YES];
}

- (NSArray *)customWindowsToExitFullScreenForWindow:(NSWindow *)window
{
    return [NSArray arrayWithObject:decoratedWindow];
}

- (void)window:(NSWindow *)window
    startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration
{
    if (!setupDone) {
        // HACK! The window has closed but Cocoa still brings it back to life
        // and shows a grey box the size of the window unless we explicitly
        // hide it by setting its alpha to 0 here.
        [window setAlphaValue:0];
        return;
    }

    // Fade out window, add back title bar and restore window frame, then fade
    // back in.  (There is a small delay before window contents is drawn after
    // the window frame is set but usually this is not noticeable on a
    // relatively modern Mac.)
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:0.5*duration];
        [[window animator] setAlphaValue:0];
    } completionHandler:^{
        [window setStyleMask:([window styleMask] & ~NSFullScreenWindowMask)];
        [tabBarControl setStyleNamed:@"Metal"];
        [self updateTablineSeparator];
        [window setFrame:preFullScreenFrame display:YES];

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            [context setDuration:0.5*duration];
            [[window animator] setAlphaValue:1];
        } completionHandler:^{
            // Do nothing
        }];
    }];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    // ASSUMPTION: fullScreenEnabled always reflects the state of Vim's 'fu'.
    if (fullScreenEnabled) {
        ASLogDebug(@"Full-screen out of sync, tell Vim to clear 'fu'");
        // NOTE: If we get here it means that Cocoa has somehow exited
        // full-screen without us getting to clear the 'fu' option first, so
        // Vim and the GUI are out of sync.  The following code (eventually)
        // gets them back into sync.
        fullScreenEnabled = NO;
        [self invFullScreen:self];
    }
}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window
{
    // TODO: Is this the correct way to deal with this message?  Are we still
    // in full-screen at this point?
    ASLogNotice(@"Failed to EXIT full-screen, maximizing window...");

    fullScreenEnabled = YES;
    [window setAlphaValue:1];
    [window setStyleMask:([window styleMask] | NSFullScreenWindowMask)];
    [tabBarControl setStyleNamed:@"Unified"];
    [self updateTablineSeparator];
    [self maximizeWindow:fullScreenOptions];
}

#endif // (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)

@end // MMWindowController



@implementation MMWindowController (Private)

- (NSSize)contentSize
{
    // NOTE: Never query the content view directly for its size since it may
    // not return the same size as contentRectForFrameRect: (e.g. when in
    // windowed mode and the tabline separator is visible)!
    NSWindow *win = [self window];
    return [win contentRectForFrameRect:[win frame]].size;
}

- (void)adjustWindowFrame
{
    NSSize cs = [[vimView textView] cellSize];
    if (cs.width == 0 || cs.height == 0) return;

    NSSize s0 = [vimView frame].size;
    NSSize s1 = [vimView desiredSize];
    CGFloat dw = s1.width - s0.width;
    CGFloat dh = s1.height - s0.height;

    if (abs(dw) > 0 || abs(dh) > 0) {
        NSRect frame = [decoratedWindow frame];
        frame.size.width += dw;
        frame.size.height += dh;
        frame.origin.y -= dh;

        // Make sure window still fits on the screen before resizing it.  If
        // there are multiple screens, this will cause the window to be
        // constrained to fit on one screen only.  Constraining the window so
        // that it fits on multiple screens is tricky, which is why we
        // constrain it to one screen only.
        NSScreen *screen = [decoratedWindow screen];
        NSRect origFrame = frame;
        if (screen) {
            // HACK: Use resizableFrame (a custom method) instead of
            // visibleFrame, otherwise it would not be possible to
            // programmatically resize the window to be as large as when
            // dragged to resize.
            NSRect container = [screen resizableFrame];
            if (frame.size.height > container.size.height)
                frame.size.height = container.size.height;
            if (frame.size.width > container.size.width)
                frame.size.width = container.size.width;
            if (frame.origin.y < container.origin.y)
                frame.origin.y = container.origin.y;
            CGFloat delta = NSMaxX(frame) - NSMaxX(container);
            if (delta > 0)
                frame.origin.x -= delta;
        }

        // NOTE: This should be the only place where the window is resized!
        [decoratedWindow setFrame:frame display:YES];

        // If we had to adjust the window frame to fit the screen then we need
        // to tell the Vim view to adjust its text view dimensions to fit the
        // current size of the window.  If we fail to do this, then repeated
        // ":set lines=900" calls could cause the text view to be too large to
        // fit the window.
        if (!NSEqualRects(frame, origFrame))
            [vimView adjustTextViewDimensions];
    }
}

- (void)resizeWindowToFitContentSize:(NSSize)contentSize
                        keepOnScreen:(BOOL)onScreen
{
    NSRect frame = [decoratedWindow frame];
    NSRect contentRect = [decoratedWindow contentRectForFrameRect:frame];

    // Keep top-left corner of the window fixed when resizing.
    contentRect.origin.y -= contentSize.height - contentRect.size.height;
    contentRect.size = contentSize;

    NSRect newFrame = [decoratedWindow frameRectForContentRect:contentRect];

    if (shouldRestoreUserTopLeft) {
        // Restore user top left window position (which is saved when zooming).
        CGFloat dy = userTopLeft.y - NSMaxY(newFrame);
        newFrame.origin.x = userTopLeft.x;
        newFrame.origin.y += dy;
        shouldRestoreUserTopLeft = NO;
    }

    NSScreen *screen = [decoratedWindow screen];
    if (onScreen && screen) {
        // Ensure that the window fits inside the visible part of the screen.
        // If there are more than one screen the window will be moved to fit
        // entirely in the screen that most of it occupies.
        NSRect maxFrame = fullScreenEnabled ? [screen frame]
                                            : [screen visibleFrame];
        maxFrame = [self constrainFrame:maxFrame];

        if (newFrame.size.width > maxFrame.size.width) {
            newFrame.size.width = maxFrame.size.width;
            newFrame.origin.x = maxFrame.origin.x;
        }
        if (newFrame.size.height > maxFrame.size.height) {
            newFrame.size.height = maxFrame.size.height;
            newFrame.origin.y = maxFrame.origin.y;
        }

        if (newFrame.origin.y < maxFrame.origin.y)
            newFrame.origin.y = maxFrame.origin.y;
        if (NSMaxY(newFrame) > NSMaxY(maxFrame))
            newFrame.origin.y = NSMaxY(maxFrame) - newFrame.size.height;
        if (newFrame.origin.x < maxFrame.origin.x)
            newFrame.origin.x = maxFrame.origin.x;
        if (NSMaxX(newFrame) > NSMaxX(maxFrame))
            newFrame.origin.x = NSMaxX(maxFrame) - newFrame.size.width;
    }

    if (fullScreenEnabled && screen) {
        // Keep window centered when in native full-screen.
        NSRect screenFrame = [screen frame];
        newFrame.origin.y = screenFrame.origin.y +
            round(0.5*(screenFrame.size.height - newFrame.size.height));
        newFrame.origin.x = screenFrame.origin.x +
            round(0.5*(screenFrame.size.width - newFrame.size.width));
    }

    ASLogDebug(@"Set window frame: %@", NSStringFromRect(newFrame));
    [decoratedWindow setFrame:newFrame display:YES];

    NSPoint oldTopLeft = { frame.origin.x, NSMaxY(frame) };
    NSPoint newTopLeft = { newFrame.origin.x, NSMaxY(newFrame) };
    if (!NSEqualPoints(oldTopLeft, newTopLeft)) {
        // NOTE: The window top left position may change due to the window
        // being moved e.g. when the tabline is shown so we must tell Vim what
        // the new window position is here.
        // NOTE 2: Vim measures Y-coordinates from top of screen.
        int pos[2] = {
            (int)newTopLeft.x,
            (int)(NSMaxY([[decoratedWindow screen] frame]) - newTopLeft.y) };
        NSData *data = [NSData dataWithBytes:pos length:2*sizeof(int)];
        [vimController sendMessage:SetWindowPositionMsgID data:data];
    }
}

- (NSSize)constrainContentSizeToScreenSize:(NSSize)contentSize
{
    NSWindow *win = [self window];
    if (![win screen])
        return contentSize;

    // NOTE: This may be called in both windowed and full-screen mode.  The
    // "visibleFrame" method does not overlap menu and dock so should not be
    // used in full-screen.
    NSRect screenRect = fullScreenEnabled ? [[win screen] frame]
                                          : [[win screen] visibleFrame];
    NSRect rect = [win contentRectForFrameRect:screenRect];

    if (contentSize.height > rect.size.height)
        contentSize.height = rect.size.height;
    if (contentSize.width > rect.size.width)
        contentSize.width = rect.size.width;

    return contentSize;
}

- (NSRect)constrainFrame:(NSRect)frame
{
    // Constrain the given (window) frame so that it fits an even number of
    // rows and columns.
    NSRect contentRect = [decoratedWindow contentRectForFrameRect:frame];
    NSSize constrainedSize = [vimView constrainRows:NULL
                                            columns:NULL
                                             toSize:contentRect.size];

    contentRect.origin.y += contentRect.size.height - constrainedSize.height;
    contentRect.size = constrainedSize;

    return [decoratedWindow frameRectForContentRect:contentRect];
}

- (void)updateResizeConstraints
{
#if 0
    if (!setupDone) return;

    // Set the resize increments to exactly match the font size; this way the
    // window will always hold an integer number of (rows,columns).
    NSSize cellSize = [[vimView textView] cellSize];
    [decoratedWindow setContentResizeIncrements:cellSize];

    NSSize minSize = [vimView minSize];
    [decoratedWindow setContentMinSize:minSize];
#endif
}

- (NSTabViewItem *)addNewTabViewItem
{
    // NOTE!  A newly created tab is not by selected by default; Vim decides
    // which tab should be selected at all times.  However, the AppKit will
    // automatically select the first tab added to a tab view.

    NSTabViewItem *tvi = [[NSTabViewItem alloc] initWithIdentifier:nil];

    // NOTE: If this is the first tab it will be automatically selected.
    vimTaskSelectedTab = YES;
    [tabView addTabViewItem:tvi];
    vimTaskSelectedTab = NO;

    [tvi autorelease];

    return tvi;
}

- (BOOL)askBackendForStarRegister:(NSPasteboard *)pb
{ 
    // TODO: Can this be done with evaluateExpression: instead?
    BOOL reply = NO;
    id backendProxy = [vimController backendProxy];

    if (backendProxy) {
        @try {
            reply = [backendProxy starRegisterToPasteboard:pb];
        }
        @catch (NSException *ex) {
            ASLogDebug(@"starRegisterToPasteboard: failed: pid=%d reason=%@",
                    [vimController pid], ex);
        }
    }

    return reply;
}

- (BOOL)hasTablineSeparator
{
    BOOL tabBarVisible = ![tabBarControl isHidden];
    if (fullScreenEnabled || tabBarVisible) {
        return NO;
    } else {
        BOOL toolbarVisible = [decoratedWindow toolbar] != nil;
        BOOL windowTextured = ([decoratedWindow styleMask] &
                                NSTexturedBackgroundWindowMask) != 0;
        return toolbarVisible || windowTextured;
    }
    return NO;
}

- (void)updateTablineSeparator
{
    [self hideTablineSeparator:![self hasTablineSeparator]];
}

- (void)hideTablineSeparator:(BOOL)hide
{
    // The full-screen window has no tabline separator so we operate on
    // decoratedWindow instead of [self window].
    if ([decoratedWindow hideTablineSeparator:hide]) {
        // The tabline separator was toggled so the content view must change
        // size.
        [self updateResizeConstraints];
        shouldPlaceVimView = YES;

#if 1
        NSSize size = [[decoratedWindow contentView] frame].size;
        if (hide) ++size.height;
        else      --size.height;

        [splitView setFrameSize:size];
#endif
    }
}

- (void)doFindNext:(BOOL)next
{
    NSString *query = nil;

#if 0
    // Use current query if the search field is selected.
    id searchField = [[self searchFieldItem] view];
    if (searchField && [[searchField stringValue] length] > 0 &&
            [decoratedWindow firstResponder] == [searchField currentEditor])
        query = [searchField stringValue];
#endif

    if (!query) {
        // Use find pasteboard for next query.
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSFindPboard];
        NSArray *supportedTypes = [NSArray arrayWithObjects:VimFindPboardType,
                NSStringPboardType, nil];
        NSString *bestType = [pb availableTypeFromArray:supportedTypes];

        // See gui_macvim_add_to_find_pboard() for an explanation of these
        // types.
        if ([bestType isEqual:VimFindPboardType])
            query = [pb stringForType:VimFindPboardType];
        else
            query = [pb stringForType:NSStringPboardType];
    }

    NSString *input = nil;
    if (query) {
        // NOTE: The '/' register holds the last search string.  By setting it
        // (using the '@/' syntax) we fool Vim into thinking that it has
        // already searched for that string and then we can simply use 'n' or
        // 'N' to find the next/previous match.
        input = [NSString stringWithFormat:@"<C-\\><C-N>:let @/='%@'<CR>%c",
                query, next ? 'n' : 'N'];
    } else {
        input = next ? @"<C-\\><C-N>n" : @"<C-\\><C-N>N"; 
    }

    [vimController addVimInput:input];
}

- (void)updateToolbar
{
    if (nil == toolbar || 0 == updateToolbarFlag) return;

    // Positive flag shows toolbar, negative hides it.
    BOOL on = updateToolbarFlag > 0 ? YES : NO;
    [decoratedWindow setToolbar:(on ? toolbar : nil)];
    [self updateTablineSeparator];

    updateToolbarFlag = 0;
}

- (NSUInteger)representedIndexOfTabViewItem:(NSTabViewItem *)tvi
{
    NSArray *tabViewItems = [tabBarControl representedTabViewItems];
    return [tabViewItems indexOfObject:tvi];
}

- (void)enterCustomFullscreen
{
    ASLogDebug(@"Enable full-screen now");

    // Hide Dock and menu bar now to avoid the hide animation from playing
    // after the fade to black (see also windowDidBecomeMain:).
    if ([fullScreenWindow isOnPrimaryScreen])
        SetSystemUIMode(kUIModeAllSuppressed, 0);

    // Fade to black
    Boolean didBlend = NO;
    CGDisplayFadeReservationToken token;
    if (CGAcquireDisplayFadeReservation(.5, &token) == kCGErrorSuccess) {
        CGDisplayFade(token, .25, kCGDisplayBlendNormal,
            kCGDisplayBlendSolidColor, .0, .0, .0, true);
        didBlend = YES;
    }

    // NOTE: The window may have moved to another screen in between init.. and
    // this call so set the frame again just in case.
    [fullScreenWindow setFrame:[[decoratedWindow screen] frame] display:NO];

    [decoratedWindow setDelegate:nil];
    [self setWindow:fullScreenWindow];

    // Move views from decorated to full-screen window
    [tabBarControl removeFromSuperviewWithoutNeedingDisplay];
    [splitView removeFromSuperviewWithoutNeedingDisplay];
    NSView *view = [fullScreenWindow contentView];
    [view addSubview:tabBarControl];
    [view addSubview:splitView];

    // Adjust view sizes
    NSRect frame = [view frame];
    NSRect tabFrame = { { 0, frame.size.height - 22 },
                        { frame.size.width, 22 } };
    [tabBarControl setFrame:tabFrame];

    if (![tabBarControl isHidden])
        frame.size.height -= 22;
    [splitView setFrame:frame];

    [fullScreenWindow setInitialFirstResponder:[vimView textView]];

    // NOTE: Calling setTitle:nil causes an exception to be raised (and it is
    // possible that the decorated window has no title when we get here).
    if ([decoratedWindow title]) {
        [self setTitle:[decoratedWindow title]];

        // NOTE: Cocoa does not add borderless windows to the "Window" menu so
        // we have to do it manually.
        [NSApp changeWindowsItem:fullScreenWindow
                           title:[decoratedWindow title]
                        filename:NO];
    }

    [fullScreenWindow setOpaque:[decoratedWindow isOpaque]];

    // Don't set this sooner, so we don't get an additional focus gained
    // message.
    [fullScreenWindow setDelegate:self];

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
    // HACK! Put window on all Spaces to avoid Spaces (available on OS X 10.5
    // and later) from moving the full screen window to a separate Space from
    // the one the decorated window is occupying.  The collection behavior is
    // restored further down.
    NSWindowCollectionBehavior wcb = [fullScreenWindow collectionBehavior];
    [fullScreenWindow setCollectionBehavior:
                                NSWindowCollectionBehaviorCanJoinAllSpaces];
#endif

    [decoratedWindow orderOut:self];
    [fullScreenWindow makeKeyAndOrderFront:self];

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
    // Restore collection behavior (see hack above).
    [fullScreenWindow setCollectionBehavior:wcb];
#endif

    // Fade back in
    if (didBlend) {
        CGDisplayFade(token, .25, kCGDisplayBlendSolidColor,
            kCGDisplayBlendNormal, .0, .0, .0, false);
        CGReleaseDisplayFadeReservation(token);
    }
}

- (void)leaveCustomFullscreen
{
    // Fade to black
    Boolean didBlend = NO;
    CGDisplayFadeReservationToken token;
    if (CGAcquireDisplayFadeReservation(.5, &token) == kCGErrorSuccess) {
        CGDisplayFade(token, .25, kCGDisplayBlendNormal,
            kCGDisplayBlendSolidColor, .0, .0, .0, true);
        didBlend = YES;
    }

    // Enusre menu bar / Dock is visible
    SetSystemUIMode(kUIModeNormal, 0);

    [self setWindow:decoratedWindow];
    [fullScreenWindow setDelegate:nil];

    // Move views from full-screen to decorated window.
    // Do this _after_ resetting delegate and window controller, so the window
    // controller doesn't get a focus lost message from the full-screen window.
    NSView *view = [decoratedWindow contentView];
    [tabBarControl removeFromSuperviewWithoutNeedingDisplay];
    [splitView removeFromSuperviewWithoutNeedingDisplay];
    [view addSubview:tabBarControl];
    [view addSubview:splitView];

    // Adjust view sizes
    NSRect frame = [decoratedWindow contentRectForFrameRect:
                                                    [decoratedWindow frame]];
    NSRect tabFrame = { { 0, frame.size.height - 22 },
                        { frame.size.width, 22 } };
    [tabBarControl setFrame:tabFrame];

    if (![tabBarControl isHidden])
        frame.size.height -= 22;
    frame.origin.x = frame.origin.y = 0;
    [splitView setFrame:frame];

    // Set the text view to initial first responder, otherwise the 'plus'
    // button on the tabline steals the first responder status.
    [decoratedWindow setInitialFirstResponder:[vimView textView]];

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
    // HACK! Put decorated window on all Spaces (available on OS X 10.5 and
    // later) so that the decorated window stays on the same Space as the full
    // screen window (they may occupy different Spaces e.g. if the full screen
    // window was dragged to another Space).  The collection behavior is
    // restored further down.
    NSWindowCollectionBehavior wcb = [decoratedWindow collectionBehavior];
    [decoratedWindow setCollectionBehavior:
                                NSWindowCollectionBehaviorCanJoinAllSpaces];
#endif

    [fullScreenWindow close];

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    // HACK! On Mac OS X 10.7 windows animate when makeKeyAndOrderFront: is
    // called.  This is distracting here, so disable the animation and restore
    // animation behavior after calling makeKeyAndOrderFront:.
    NSWindowAnimationBehavior a = NSWindowAnimationBehaviorNone;
    if ([decoratedWindow respondsToSelector:@selector(animationBehavior)]) {
        a = [decoratedWindow animationBehavior];
        [decoratedWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];
    }
#endif

    [decoratedWindow makeKeyAndOrderFront:self];

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    // HACK! Restore animation behavior.
    if (NSWindowAnimationBehaviorNone != a)
        [decoratedWindow setAnimationBehavior:a];
#endif

#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5)
    // Restore collection behavior (see hack above).
    [decoratedWindow setCollectionBehavior:wcb];
#endif

    // ...but we don't want a focus gained message either, so don't set this
    // sooner
    [decoratedWindow setDelegate:self];

    // Fade back in  
    if (didBlend) {
        CGDisplayFade(token, .25, kCGDisplayBlendSolidColor,
            kCGDisplayBlendNormal, .0, .0, .0, false);
        CGReleaseDisplayFadeReservation(token);
    }

    ASLogDebug(@"Disabled full-screen");
}

- (BOOL)maximizeWindow:(int)options
{
#if 0
    int currRows, currColumns;
    [[vimView textView] getMaxRows:&currRows columns:&currColumns];

    // NOTE: Do not use [NSScreen visibleFrame] when determining the screen
    // size since it compensates for menu and dock.
    int maxRows, maxColumns;
    NSSize size = [[NSScreen mainScreen] frame].size;
    [vimView constrainRows:&maxRows columns:&maxColumns toSize:size];

    ASLogDebug(@"Window dimensions max: %dx%d  current: %dx%d",
            maxRows, maxColumns, currRows, currColumns);

    // Compute current fu size
    int fuRows = currRows, fuColumns = currColumns;
    if (options & FUOPT_MAXVERT)
        fuRows = maxRows;
    if (options & FUOPT_MAXHORZ)
        fuColumns = maxColumns;

    // If necessary, resize vim to target fu size
    if (currRows != fuRows || currColumns != fuColumns) {
        // The size sent here is queued and sent to vim when it's in
        // event processing mode again. Make sure to only send the values we
        // care about, as they override any changes that were made to 'lines'
        // and 'columns' after 'fu' was set but before the event loop is run.
        NSData *data = nil;
        int msgid = 0;
        if (currRows != fuRows && currColumns != fuColumns) {
            int newSize[2] = { fuRows, fuColumns };
            data = [NSData dataWithBytes:newSize length:2*sizeof(int)];
            msgid = SetTextDimensionsMsgID;
        } else if (currRows != fuRows) {
            data = [NSData dataWithBytes:&fuRows length:sizeof(int)];
            msgid = SetTextRowsMsgID;
        } else if (currColumns != fuColumns) {
            data = [NSData dataWithBytes:&fuColumns length:sizeof(int)];
            msgid = SetTextColumnsMsgID;
        }
        NSParameterAssert(data != nil && msgid != 0);

        ASLogDebug(@"%s: %dx%d", MessageStrings[msgid], fuRows, fuColumns);
        MMVimController *vc = [self vimController];
        [vc sendMessage:msgid data:data];
        [[vimView textView] setMaxRows:fuRows columns:fuColumns];

        // Indicate that window was resized
        return YES;
    }

    // Indicate that window was not resized
    return NO;
#else
    [decoratedWindow setFrame:[[decoratedWindow screen] frame] display:NO];
    return NO;
#endif
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
    if (fullScreenWindow) {
        // This notification is sent when screen resolution may have changed (e.g.
        // due to a monitor being unplugged or the resolution being changed
        // manually) but it also seems to get called when the Dock is
        // hidden/displayed.
        ASLogDebug(@"Screen unplugged / resolution changed");

        if (fullScreenEnabled) {
            NSScreen *screen = [decoratedWindow screen];
            if (!screen) {
                // Paranoia: if window we originally used for full screen is gone,
                // try screen window is on now, and failing that (not sure this can
                // happen) use main screen.
                screen = [fullScreenWindow screen];
                if (!screen)
                    screen = [NSScreen mainScreen];
            }

            // Ensure the full screen window is still covering the entire screen
            // and then resize view according to 'fuopt'.
            [fullScreenWindow setFrame:[screen frame] display:NO];
        }
    } else if (fullScreenEnabled) {
        ASLogDebug(@"Re-maximizing full-screen window...");
        [self maximizeWindow:fullScreenOptions];
    }
}

- (void)enterNativeFullScreen
{
    if (fullScreenEnabled)
        return;

    ASLogInfo(@"Enter native full-screen");

    fullScreenEnabled = YES;

    // NOTE: fullScreenEnabled is used to detect if we enter full-screen
    // programatically and so must be set before calling realToggleFullScreen:.
    NSParameterAssert(fullScreenEnabled == YES);
    [decoratedWindow realToggleFullScreen:self];
}

@end // MMWindowController (Private)

