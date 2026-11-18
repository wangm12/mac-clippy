#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MacClippyObjectiveCExceptionDomain;
FOUNDATION_EXPORT NSString * const MacClippyObjectiveCExceptionNameKey;
FOUNDATION_EXPORT NSString * const MacClippyObjectiveCExceptionReasonKey;
FOUNDATION_EXPORT NSString * const MacClippyObjectiveCExceptionCallStackKey;
FOUNDATION_EXPORT NSString * const MacClippyNativeOperationCompletedKey;

// Each function performs one pasteboard operation in Objective-C and catches
// any NSException before control returns to Swift. A NO return means the
// native operation raised; ordinary nil/false values are reported through
// the output parameter while the function itself still returns YES.
FOUNDATION_EXPORT BOOL MacClippyPasteboardReadChangeCount(
    NSPasteboard *pasteboard,
    NSInteger *changeCount,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadItems(
    NSPasteboard *pasteboard,
    id _Nullable __autoreleasing * _Nonnull items,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadBoardTypes(
    NSPasteboard *pasteboard,
    id _Nullable __autoreleasing * _Nonnull types,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadItemTypes(
    NSPasteboardItem *item,
    id _Nullable __autoreleasing * _Nonnull types,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadItemData(
    NSPasteboardItem *item,
    NSPasteboardType type,
    id _Nullable __autoreleasing * _Nonnull data,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadItemString(
    NSPasteboardItem *item,
    NSPasteboardType type,
    id _Nullable __autoreleasing * _Nonnull string,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadBoardData(
    NSPasteboard *pasteboard,
    NSPasteboardType type,
    id _Nullable __autoreleasing * _Nonnull data,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardReadBoardString(
    NSPasteboard *pasteboard,
    NSPasteboardType type,
    id _Nullable __autoreleasing * _Nonnull string,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardClearContents(
    NSPasteboard *pasteboard,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardWriteObjects(
    NSPasteboard *pasteboard,
    NSArray<id<NSPasteboardWriting>> *objects,
    NSInteger *didWrite,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardSetItemData(
    NSPasteboardItem *item,
    NSData *data,
    NSPasteboardType type,
    NSInteger *didSet,
    NSError * _Nullable __autoreleasing * _Nullable error
);

FOUNDATION_EXPORT BOOL MacClippyPasteboardSetItemString(
    NSPasteboardItem *item,
    NSString *string,
    NSPasteboardType type,
    NSInteger *didSet,
    NSError * _Nullable __autoreleasing * _Nullable error
);

// Deterministic native-boundary fault injection for the platform tests. The
// next matching narrow operation performs its real AppKit call, then raises
// and catches a synthetic NSException inside that Objective-C operation.
FOUNDATION_EXPORT void MacClippyPasteboardInjectExceptionForTesting(NSString *operation, NSInteger matchingOperationsToSkip);

NS_ASSUME_NONNULL_END
