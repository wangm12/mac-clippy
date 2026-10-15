#import "MacClippyObjCExceptionSupport.h"

NSString * const MacClippyObjectiveCExceptionDomain = @"com.macallyouneed.macclippy.objective-c-exception";
NSString * const MacClippyObjectiveCExceptionNameKey = @"MacClippyObjectiveCExceptionName";
NSString * const MacClippyObjectiveCExceptionReasonKey = @"MacClippyObjectiveCExceptionReason";
NSString * const MacClippyObjectiveCExceptionCallStackKey = @"MacClippyObjectiveCExceptionCallStack";
NSString * const MacClippyNativeOperationCompletedKey = @"MacClippyNativeOperationCompleted";

static NSLock *MacClippyInjectionLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

static NSString *MacClippyInjectedOperation;
static NSInteger MacClippyInjectedOperationsToSkip;

void MacClippyPasteboardInjectExceptionForTesting(NSString *operation, NSInteger matchingOperationsToSkip) {
    [MacClippyInjectionLock() lock];
    MacClippyInjectedOperation = [operation copy];
    MacClippyInjectedOperationsToSkip = MAX(0, matchingOperationsToSkip);
    [MacClippyInjectionLock() unlock];
}

static void MacClippyRaiseInjectedExceptionAfterOperation(NSString *operation) {
    BOOL shouldRaise = NO;
    [MacClippyInjectionLock() lock];
    if ([MacClippyInjectedOperation isEqualToString:operation]) {
        if (MacClippyInjectedOperationsToSkip > 0) {
            MacClippyInjectedOperationsToSkip -= 1;
        } else {
            MacClippyInjectedOperation = nil;
            shouldRaise = YES;
        }
    }
    [MacClippyInjectionLock() unlock];

    if (shouldRaise) {
        @throw [NSException exceptionWithName:@"MacClippyInjectedPasteboardException"
                                       reason:[NSString stringWithFormat:@"Injected after %@", operation]
                                     userInfo:nil];
    }
}

static NSString *MacClippyBoundedString(NSString *value, NSUInteger maximumLength) {
    if (value.length <= maximumLength) return value;
    return [value substringToIndex:maximumLength];
}

static NSError *MacClippyErrorFromException(NSString *operation, NSException *exception) {
    NSString *name = MacClippyBoundedString(exception.name ?: @"NSException", 128);
    NSString *reason = MacClippyBoundedString(exception.reason ?: @"", 512);
    NSArray<NSString *> *rawCallStack = exception.callStackSymbols ?: @[];
    NSMutableArray<NSString *> *callStack = [NSMutableArray arrayWithCapacity:MIN(rawCallStack.count, 8)];
    for (NSString *frame in [rawCallStack subarrayWithRange:NSMakeRange(0, MIN(rawCallStack.count, 8))]) {
        [callStack addObject:MacClippyBoundedString(frame, 256)];
    }
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ raised %@", operation, name],
        MacClippyObjectiveCExceptionNameKey: name,
        MacClippyObjectiveCExceptionReasonKey: reason,
        MacClippyObjectiveCExceptionCallStackKey: callStack,
    };
    return [NSError errorWithDomain:MacClippyObjectiveCExceptionDomain code:1 userInfo:userInfo];
}

#define MACCLIPPY_NATIVE_TRY(operationName, nativeExpression, errorPointer) \
    @try { \
        nativeExpression; \
        MacClippyRaiseInjectedExceptionAfterOperation(operationName); \
        return YES; \
    } @catch (NSException *exception) { \
        if (errorPointer != NULL) *errorPointer = MacClippyErrorFromException(operationName, exception); \
        return NO; \
    }

BOOL MacClippyPasteboardReadChangeCount(NSPasteboard *pasteboard, NSInteger *changeCount, NSError **error) {
    @try {
        *changeCount = pasteboard.changeCount;
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.change-count");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.change-count", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadItems(NSPasteboard *pasteboard, id *items, NSError **error) {
    @try {
        *items = pasteboard.pasteboardItems ?: @[];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.items");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.items", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadBoardTypes(NSPasteboard *pasteboard, id *types, NSError **error) {
    @try {
        id value = pasteboard.types;
        *types = value ?: @[];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.board-types");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.board-types", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadItemTypes(NSPasteboardItem *item, id *types, NSError **error) {
    @try {
        id value = item.types;
        *types = value ?: @[];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.item-types");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.item-types", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadItemData(NSPasteboardItem *item, NSPasteboardType type, id *data, NSError **error) {
    @try {
        *data = [item dataForType:type];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.item-data");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.item-data", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadItemString(NSPasteboardItem *item, NSPasteboardType type, id *string, NSError **error) {
    @try {
        *string = [item stringForType:type];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.item-string");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.item-string", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadBoardData(NSPasteboard *pasteboard, NSPasteboardType type, id *data, NSError **error) {
    @try {
        *data = [pasteboard dataForType:type];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.board-data");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.board-data", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardReadBoardString(NSPasteboard *pasteboard, NSPasteboardType type, id *string, NSError **error) {
    @try {
        *string = [pasteboard stringForType:type];
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.board-string");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.board-string", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardClearContents(NSPasteboard *pasteboard, NSError **error) {
    BOOL didClear = NO;
    @try {
        [pasteboard clearContents];
        didClear = YES;
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.clear");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSError *nativeError = MacClippyErrorFromException(@"pasteboard.clear", exception);
            if (didClear) {
                NSMutableDictionary *userInfo = [nativeError.userInfo mutableCopy];
                userInfo[MacClippyNativeOperationCompletedKey] = @YES;
                nativeError = [NSError errorWithDomain:nativeError.domain code:nativeError.code userInfo:userInfo];
            }
            *error = nativeError;
        }
        return NO;
    }
}

BOOL MacClippyPasteboardWriteObjects(NSPasteboard *pasteboard, NSArray<id<NSPasteboardWriting>> *objects, NSInteger *didWrite, NSError **error) {
    @try {
        *didWrite = [pasteboard writeObjects:objects] ? 1 : 0;
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.write-objects");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.write-objects", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardSetItemData(NSPasteboardItem *item, NSData *data, NSPasteboardType type, NSInteger *didSet, NSError **error) {
    @try {
        *didSet = [item setData:data forType:type] ? 1 : 0;
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.set-item-data");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.set-item-data", exception);
        return NO;
    }
}

BOOL MacClippyPasteboardSetItemString(NSPasteboardItem *item, NSString *string, NSPasteboardType type, NSInteger *didSet, NSError **error) {
    @try {
        *didSet = [item setString:string forType:type] ? 1 : 0;
        MacClippyRaiseInjectedExceptionAfterOperation(@"pasteboard.set-item-string");
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = MacClippyErrorFromException(@"pasteboard.set-item-string", exception);
        return NO;
    }
}

#undef MACCLIPPY_NATIVE_TRY
