#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// In-process fake native objects for boundary validation tests. These never
// use NSPasteboard.general and contain only fixed synthetic strings.
FOUNDATION_EXPORT NSPasteboard *MacClippyMakeMalformedPasteboard(NSInteger mode);
FOUNDATION_EXPORT NSPasteboard *MacClippyMakeForeignClearAfterFailedNativeClearPasteboard(void);
FOUNDATION_EXPORT NSPasteboardItem *MacClippyMakeMalformedPasteboardItem(NSInteger mode);
FOUNDATION_EXPORT void MacClippySetSyntheticPasteboardContents(
    NSPasteboard *pasteboard,
    NSInteger changeCount,
    NSString *text
);

NS_ASSUME_NONNULL_END
