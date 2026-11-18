#import "MacClippyPlatformTestObjCSupport.h"

enum {
    G9FixtureValid = 0,
    G9FixtureItemsNotArray = 1,
    G9FixtureItemsContainWrongType = 2,
    G9FixtureBoardTypesNotArray = 3,
    G9FixtureBoardTypesContainWrongType = 4,
    G9FixtureItemTypesNotArray = 5,
    G9FixtureItemTypesContainWrongType = 6,
    G9FixtureItemDataWrongType = 7,
    G9FixtureItemStringWrongType = 8,
    G9FixtureForeignWriteAfterClear = 9,
    G9FixtureForeignData = 10,
    G10FixtureExternalClearPrecedesFailedNativeClear = 11,
};

@interface G9MalformedPasteboardItem : NSPasteboardItem
@property(nonatomic) NSInteger fixtureMode;
@property(nonatomic, copy) NSString *fixtureText;
@end

@implementation G9MalformedPasteboardItem
- (NSArray<NSPasteboardType> *)types {
    if (self.fixtureMode == G9FixtureItemTypesNotArray) {
        return (id)[NSSet setWithObject:NSPasteboardTypeString];
    }
    if (self.fixtureMode == G9FixtureItemTypesContainWrongType) {
        return (id)@[ @42 ];
    }
    return @[ NSPasteboardTypeString ];
}

- (NSData *)dataForType:(NSPasteboardType)type {
    if (self.fixtureMode == G9FixtureItemDataWrongType) return (id)@42;
    if ([type isEqualToString:NSPasteboardTypeString]) {
        if (self.fixtureMode == G9FixtureForeignData) {
            return [NSData dataWithBytes:"foreign generation" length:18];
        }
        NSString *value = self.fixtureText ?: @"fixture text";
        return [value dataUsingEncoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (NSString *)stringForType:(NSPasteboardType)type {
    if (self.fixtureMode == G9FixtureItemStringWrongType) return (id)@42;
    if (self.fixtureMode == G9FixtureForeignData && [type isEqualToString:NSPasteboardTypeString]) {
        return @"foreign generation";
    }
    if (![type isEqualToString:NSPasteboardTypeString]) return nil;
    return self.fixtureText ?: @"fixture text";
}
@end

@interface G9MalformedPasteboard : NSObject
@property(nonatomic, copy) NSString *fixtureName;
@property(nonatomic) NSInteger fixtureMode;
@property(nonatomic) NSInteger fixtureChangeCount;
@property(nonatomic, copy) NSArray *fixtureItems;
@end

@implementation G9MalformedPasteboard
- (NSString *)name { return self.fixtureName; }
- (NSInteger)changeCount { return self.fixtureChangeCount; }

- (NSArray<NSPasteboardItem *> *)pasteboardItems {
    if (self.fixtureMode == G9FixtureItemsNotArray) return (id)@"not-an-array";
    if (self.fixtureMode == G9FixtureItemsContainWrongType) return (id)@[ @"not-a-pasteboard-item" ];
    return self.fixtureItems;
}

- (NSArray<NSPasteboardType> *)types {
    if (self.fixtureMode == G9FixtureBoardTypesNotArray) {
        return (id)[NSSet setWithObject:NSPasteboardTypeString];
    }
    if (self.fixtureMode == G9FixtureBoardTypesContainWrongType) return (id)@[ @42 ];
    return @[ NSPasteboardTypeString ];
}

- (NSData *)dataForType:(NSPasteboardType)type {
    if (![type isEqualToString:NSPasteboardTypeString]) return nil;
    id item = self.fixtureItems.firstObject;
    return [item respondsToSelector:@selector(dataForType:)] ? [item dataForType:type] : nil;
}

- (NSString *)stringForType:(NSPasteboardType)type {
    if (![type isEqualToString:NSPasteboardTypeString]) return nil;
    id item = self.fixtureItems.firstObject;
    return [item respondsToSelector:@selector(stringForType:)] ? [item stringForType:type] : nil;
}

- (void)clearContents {
    if (self.fixtureMode == G10FixtureExternalClearPrecedesFailedNativeClear) {
        // Model an external app clearing the named pasteboard after the
        // caller's last generation check but before its own native clear
        // completes. The production selector then throws before its own
        // operation can be proven complete.
        self.fixtureChangeCount += 1;
        self.fixtureItems = @[];
        @throw [NSException exceptionWithName:@"G10NativeClearFailedBeforeOwnedMutation"
                                       reason:@"synthetic external clear followed by failed native clear"
                                     userInfo:nil];
    }
    if (self.fixtureMode == G9FixtureForeignWriteAfterClear) {
        self.fixtureChangeCount += 2;
        G9MalformedPasteboardItem *foreignItem = [G9MalformedPasteboardItem new];
        foreignItem.fixtureMode = G9FixtureForeignData;
        self.fixtureItems = @[ foreignItem ];
        return;
    }
    self.fixtureChangeCount += 1;
    self.fixtureItems = @[];
}

- (BOOL)writeObjects:(NSArray<id<NSPasteboardWriting>> *)objects {
    self.fixtureItems = objects;
    return YES;
}
@end

NSPasteboard *MacClippyMakeMalformedPasteboard(NSInteger mode) {
    G9MalformedPasteboard *pasteboard = [G9MalformedPasteboard new];
    pasteboard.fixtureName = [NSString stringWithFormat:@"com.example.macclippy.synthetic.%@", NSUUID.UUID.UUIDString];
    pasteboard.fixtureMode = mode;
    pasteboard.fixtureChangeCount = 19;
    G9MalformedPasteboardItem *item = [G9MalformedPasteboardItem new];
    item.fixtureMode = mode;
    pasteboard.fixtureItems = @[ item ];
    return (id)pasteboard;
}

NSPasteboard *MacClippyMakeForeignClearAfterFailedNativeClearPasteboard(void) {
    return MacClippyMakeMalformedPasteboard(G10FixtureExternalClearPrecedesFailedNativeClear);
}

NSPasteboardItem *MacClippyMakeMalformedPasteboardItem(NSInteger mode) {
    G9MalformedPasteboardItem *item = [G9MalformedPasteboardItem new];
    item.fixtureMode = mode;
    return item;
}

void MacClippySetSyntheticPasteboardContents(NSPasteboard *pasteboard, NSInteger changeCount, NSString *text) {
    G9MalformedPasteboard *fixture = (id)pasteboard;
    fixture.fixtureChangeCount = changeCount;
    G9MalformedPasteboardItem *item = [G9MalformedPasteboardItem new];
    item.fixtureMode = G9FixtureValid;
    item.fixtureText = text;
    fixture.fixtureItems = @[ item ];
}
