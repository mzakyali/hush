#import <AppKit/AppKit.h>

// Private NSTouchBar system-tray / system-modal API — the same surface Pock
// and MTMR use. These are declarations only; nothing links against them.
// Every call site is guarded by `responds(to:)`, so a macOS release without
// these selectors degrades to a silent no-op.

@interface NSTouchBarItem (HushPrivateTray)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

@interface NSTouchBar (HushPrivateModal)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar
                         placement:(NSInteger)placement
         systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar
         systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)bar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)bar;
@end
