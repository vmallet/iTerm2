//
//  iTermImageInfo.m
//  iTerm2
//
//  Created by George Nachman on 5/11/15.
//
//

#import "iTermImageInfo.h"

#import "DebugLogging.h"
#import "iTermAnimatedImageInfo.h"
#import "iTermImage.h"
#import "FutureMethods.h"
#import "NSData+iTerm.h"
#import "NSImage+iTerm.h"
#import "NSWorkspace+iTerm.h"

static NSString *const kImageInfoSizeKey = @"Size";
static NSString *const kImageInfoImageKey = @"Image";  // data
static NSString *const kImageInfoPreserveAspectRatioKey = @"Preserve Aspect Ratio";
static NSString *const kImageInfoFilenameKey = @"Filename";
static NSString *const kImageInfoInsetKey = @"Edge Insets";
static NSString *const kImageInfoCodeKey = @"Code";
static NSString *const kImageInfoBrokenKey = @"Broken";

NSString *const iTermImageDidLoad = @"iTermImageDidLoad";

@interface iTermImageInfo ()

@property(nonatomic, retain) NSMutableDictionary *embeddedImages;  // frame number->downscaled image
@property(nonatomic, assign) unichar code;
@property(nonatomic, retain) iTermAnimatedImageInfo *animatedImage;  // If animated GIF, this is nonnil
@end

@implementation iTermImageInfo {
    NSData *_data;
    NSString *_uniqueIdentifier;
    NSDictionary *_dictionary;
    void (^_queuedBlock)(void);
}

- (instancetype)initWithCode:(unichar)code {
    self = [super init];
    if (self) {
        _code = code;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        _size = [dictionary[kImageInfoSizeKey] sizeValue];
        _broken = [dictionary[kImageInfoBrokenKey] boolValue];
        _inset = [dictionary[kImageInfoInsetKey] futureEdgeInsetsValue];
        _data = [dictionary[kImageInfoImageKey] retain];
        _dictionary = [dictionary copy];
        _preserveAspectRatio = [dictionary[kImageInfoPreserveAspectRatioKey] boolValue];
        _filename = [dictionary[kImageInfoFilenameKey] copy];
        _code = [dictionary[kImageInfoCodeKey] shortValue];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p code=%@ size=%@ uniqueIdentifier=%@ filename=%@ broken=%@>",
            self.class, self, @(self.code), NSStringFromSize(self.size), self.uniqueIdentifier, self.filename, @(self.broken)];
}

- (NSString *)uniqueIdentifier {
    if (!_uniqueIdentifier) {
        _uniqueIdentifier = [[[NSUUID UUID] UUIDString] copy];
    }
    return _uniqueIdentifier;
}

- (void)loadFromDictionaryIfNeeded {
    static dispatch_once_t onceToken;
    static dispatch_queue_t queue;
    static NSMutableArray *blocks;
    dispatch_once(&onceToken, ^{
        blocks = [[NSMutableArray alloc] init];
        queue = dispatch_queue_create("com.iterm2.LazyImageDecoding", DISPATCH_QUEUE_SERIAL);
    });

    if (!_dictionary) {
        @synchronized (self) {
            if (_queuedBlock) {
                // Move to the head of the queue.
                NSUInteger index = [blocks indexOfObjectIdenticalTo:_queuedBlock];
                if (index != NSNotFound) {
                    [blocks removeObjectAtIndex:index];
                    [blocks insertObject:_queuedBlock atIndex:0];
                }
            }
        }
        return;
    }

    [_dictionary release];
    _dictionary = nil;

    DLog(@"Queueing load of %@", self.uniqueIdentifier);
    void (^block)(void) = ^{
        // This is a slow operation that blocks for a long time.
        iTermImage *image = [[iTermImage imageWithCompressedData:_data] retain];
        dispatch_sync(dispatch_get_main_queue(), ^{
            [image autorelease];
            [_queuedBlock release];
            _queuedBlock = nil;
            [_animatedImage autorelease];
            _animatedImage = [[iTermAnimatedImageInfo alloc] initWithImage:image];
            if (!_animatedImage) {
                _image = [image retain];
            }
            if (_image || _animatedImage) {
                DLog(@"Loaded %@", self.uniqueIdentifier);
                [[NSNotificationCenter defaultCenter] postNotificationName:iTermImageDidLoad object:self];
            }
        });
    };
    _queuedBlock = [block copy];
    @synchronized(self) {
        [blocks insertObject:_queuedBlock atIndex:0];
    }
    dispatch_async(queue, ^{
        void (^blockToRun)(void) = nil;
        @synchronized(self) {
            blockToRun = [blocks firstObject];
            [blockToRun retain];
            [blocks removeObjectAtIndex:0];
        }
        blockToRun();
        [blockToRun release];
    });
}

- (void)dealloc {
    [_filename release];
    [_image release];
    [_embeddedImages release];
    [_animatedImage release];
    [_data release];
    [_dictionary release];
    [_uniqueIdentifier release];
    [super dealloc];
}

- (void)saveToFile:(NSString *)filename {
    NSBitmapImageFileType fileType = NSBitmapImageFileTypePNG;
    if ([filename hasSuffix:@".bmp"]) {
        fileType = NSBitmapImageFileTypeBMP;
    } else if ([filename hasSuffix:@".gif"]) {
        fileType = NSBitmapImageFileTypeGIF;
    } else if ([filename hasSuffix:@".jp2"]) {
        fileType = NSBitmapImageFileTypeJPEG2000;
    } else if ([filename hasSuffix:@".jpg"] || [filename hasSuffix:@".jpeg"]) {
        fileType = NSBitmapImageFileTypeJPEG;
    } else if ([filename hasSuffix:@".png"]) {
        fileType = NSBitmapImageFileTypePNG;
    } else if ([filename hasSuffix:@".tiff"]) {
        fileType = NSBitmapImageFileTypeTIFF;
    }

    NSData *data = nil;
    NSDictionary *universalTypeToCocoaMap = @{ (NSString *)kUTTypeBMP: @(NSBitmapImageFileTypeBMP),
                                               (NSString *)kUTTypeGIF: @(NSBitmapImageFileTypeGIF),
                                               (NSString *)kUTTypeJPEG2000: @(NSBitmapImageFileTypeJPEG2000),
                                               (NSString *)kUTTypeJPEG: @(NSBitmapImageFileTypeJPEG),
                                               (NSString *)kUTTypePNG: @(NSBitmapImageFileTypePNG),
                                               (NSString *)kUTTypeTIFF: @(NSBitmapImageFileTypeTIFF) };
    NSString *imageType = self.imageType;
    if (self.broken) {
        data = self.data;
    } else if (imageType) {
        NSNumber *nsTypeNumber = universalTypeToCocoaMap[imageType];
        if (nsTypeNumber.integerValue == fileType) {
            data = self.data;
        }
    }
    if (!data) {
        NSBitmapImageRep *rep = [self.image.images.firstObject bitmapImageRep];
        data = [rep representationUsingType:fileType properties:@{}];
    }
    [data writeToFile:filename atomically:NO];
}

- (void)setImageFromImage:(iTermImage *)image data:(NSData *)data {
    [_dictionary release];
    _dictionary = nil;

    [_animatedImage autorelease];
    _animatedImage = [[iTermAnimatedImageInfo alloc] initWithImage:image];

    [_data autorelease];
    _data = [data retain];

    [_image autorelease];
    _image = [image retain];
}

- (NSString *)imageType {
    NSString *type = [_data uniformTypeIdentifierForImageData];
    if (type) {
        return type;
    }

    return (NSString *)kUTTypeImage;
}

- (NSDictionary *)dictionary {
    return @{ kImageInfoSizeKey: [NSValue valueWithSize:_size],
              kImageInfoInsetKey: [NSValue futureValueWithEdgeInsets:_inset],
              kImageInfoImageKey: _data ?: [NSData data],
              kImageInfoPreserveAspectRatioKey: @(_preserveAspectRatio),
              kImageInfoFilenameKey: _filename ?: @"",
              kImageInfoCodeKey: @(_code),
              kImageInfoBrokenKey: @(_broken) };
}


- (BOOL)animated {
    return !_paused && _animatedImage != nil;
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    _animatedImage.paused = paused;
}

- (iTermImage *)image {
    [self loadFromDictionaryIfNeeded];
    return _image;
}

- (iTermAnimatedImageInfo *)animatedImage {
    [self loadFromDictionaryIfNeeded];
    return _animatedImage;
}

- (NSImage *)imageWithCellSize:(CGSize)cellSize {
    return [self imageWithCellSize:cellSize timestamp:[NSDate timeIntervalSinceReferenceDate]];
}

- (int)frameForTimestamp:(NSTimeInterval)timestamp {
    return [self.animatedImage frameForTimestamp:timestamp];
}

- (BOOL)ready {
    return (self.image || self.animatedImage);

}
static NSSize iTermImageInfoGetSizeForRegionPreservingAspectRatio(const NSSize region,
                                                                  NSSize imageSize) {
    double imageAR = imageSize.width / imageSize.height;
    double canvasAR = region.width / region.height;
    if (imageAR > canvasAR) {
        // Image is wider than canvas, add letterboxes on top and bottom.
        return NSMakeSize(region.width, region.width / imageAR);
    } else {
        // Image is taller than canvas, add pillarboxes on sides.
        return NSMakeSize(region.height * imageAR, region.height);
    }
}

- (NSImage *)imageWithCellSize:(CGSize)cellSize timestamp:(NSTimeInterval)timestamp {
    if (!self.ready) {
        DLog(@"%@ not ready", self.uniqueIdentifier);
        return nil;
    }
    if (!_embeddedImages) {
        _embeddedImages = [[NSMutableDictionary alloc] init];
    }
    int frame = [self.animatedImage frameForTimestamp:timestamp];  // 0 if not animated
    NSImage *embeddedImage = _embeddedImages[@(frame)];

    NSSize region = NSMakeSize(cellSize.width * _size.width,
                               cellSize.height * _size.height);
    if (!NSEqualSizes(embeddedImage.size, region)) {
        NSSize size;
        NSImage *theImage;
        if (self.animatedImage) {
            theImage = [self.animatedImage imageForFrame:frame];
        } else {
            theImage = [self.image.images firstObject];
        }
        if (_preserveAspectRatio) {
            size = iTermImageInfoGetSizeForRegionPreservingAspectRatio(region, theImage.size);
        } else {
            size = region;
        }
        NSEdgeInsets inset = _inset;
        inset.top *= cellSize.height;
        inset.bottom *= cellSize.height;
        inset.left *= cellSize.width;
        inset.right *= cellSize.width;
        const NSRect destinationRect = NSMakeRect((region.width - size.width) / 2 + inset.left,
                                                  (region.height - size.height) / 2 + inset.bottom,
                                                  MAX(0, size.width - inset.left - inset.right),
                                                  MAX(0, size.height - inset.top - inset.bottom));
        NSImage *canvas = [theImage safelyResizedImageWithSize:size destinationRect:destinationRect];
        self.embeddedImages[@(frame)] = canvas;
    }
    return _embeddedImages[@(frame)];
}

+ (NSEdgeInsets)fractionalInsetsForPreservedAspectRatioWithDesiredSize:(NSSize)desiredSize
                                                          forImageSize:(NSSize)imageSize
                                                              cellSize:(NSSize)cellSize
                                                         numberOfCells:(NSSize)numberOfCells {
    const NSSize region = NSMakeSize(cellSize.width * numberOfCells.width,
                                     cellSize.height * numberOfCells.height);
    const NSSize size = iTermImageInfoGetSizeForRegionPreservingAspectRatio(region, imageSize);

    // Given the following equalities, inferred from how the destinationRect is computed when
    // creating the embedded image in -imageWithCellSize:timestamp: above:
    //
    // left = (region.width - size.width) / 2 + insets.left
    // bottom = (region.height - size.height) / 2 + insets.bottom
    // width = size.width - insets.left - insets.right
    // height = size.height - insets.top - insets.bottom
    //
    // Set left=0, bottom=0, width=desiredSize.width, height=desiredSize.height.
    // Solve for insets. Here's what you get:
    const CGFloat left = (region.width - size.width) / -2.0;
    const CGFloat bottom = (region.height - size.height) / -2.0;
    const CGFloat right = size.width - left - desiredSize.width;
    const CGFloat top = size.height - bottom - desiredSize.height;

    // To top-align, swap the bottom and top insets.
    return NSEdgeInsetsMake(bottom / cellSize.height,
                            left / cellSize.width,
                            top / cellSize.height,
                            right / cellSize.width);
}

- (NSString *)nameForNewSavedTempFile {
    NSString *name = nil;
    if (_filename.pathExtension.length) {
        // The filename has an extension. Preserve its name in the tempfile's name,
        // and especially importantly, preserve its extension.
        NSString *suffix = [@"." stringByAppendingString:_filename.lastPathComponent];
        name = [[NSWorkspace sharedWorkspace] temporaryFileNameWithPrefix:@"iTerm2."
                                                                   suffix:suffix];
    } else {
        // Empty extension case. Try to guess the extension.
        NSString *extension = [NSImage extensionForUniformType:self.imageType];
        if (extension) {
            extension = [@"." stringByAppendingString:extension];
        }
        name = [[NSWorkspace sharedWorkspace] temporaryFileNameWithPrefix:@"iTerm2."
                                                                   suffix:extension];
    }
    [self.data writeToFile:name atomically:NO];
    return name;
}

- (NSPasteboardItem *)pasteboardItem {
    NSPasteboardItem *pbItem = [[[NSPasteboardItem alloc] init] autorelease];
    NSArray *types;
    NSString *imageType = self.imageType;
    if (imageType) {
        types = @[ (NSString *)kUTTypeFileURL, (NSString *)imageType ];
    } else {
        types = @[ (NSString *)kUTTypeFileURL ];
    }
    [pbItem setDataProvider:self forTypes:types];

    return pbItem;
}

#pragma mark - NSPasteboardItemDataProvider

- (void)pasteboard:(NSPasteboard *)pasteboard item:(NSPasteboardItem *)item provideDataForType:(NSString *)type {
    if ([type isEqualToString:(NSString *)kUTTypeFileURL]) {
        // Write image to a temp file and provide its location.
        [item setString:[[NSURL fileURLWithPath:self.nameForNewSavedTempFile] absoluteString]
                forType:(NSString *)kUTTypeFileURL];
    } else {
        if ([type isEqualToString:(NSString *)kUTTypeImage] && ![_data uniformTypeIdentifierForImageData]) {
            [item setData:_data forType:type];
        } else {
            // Provide our data, which is already in the format requested by |type|.
            [item setData:self.data forType:type];
        }
    }
}

@end
