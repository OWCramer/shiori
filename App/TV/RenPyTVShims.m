// Classes the renios prebuilts (built for iPhone) reference that tvOS doesn't have, linked
// into the Apple TV Ren'Py frameworks (Scripts/tv/build-renpy-tv.sh). SDL makes a motion
// manager for its accelerometer joystick and a pointer interaction for iPad trackpads.
// Foundation only: UIKit's headers declare the pointer classes (unavailable on tvOS).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

/// No accelerometer: alloc gives nil, so SDL sees none.
@interface CMMotionManager : NSObject
@end
@implementation CMMotionManager
+ (instancetype)alloc { return nil; }
@end

/// An interaction that does nothing; tvOS has no pointer.
@interface UIPointerInteraction : NSObject
@property (nonatomic, weak, readonly) id view;
@end
@implementation UIPointerInteraction {
    __weak id _view;
}
+ (void)load {
    Protocol *interaction = objc_getProtocol("UIInteraction");
    if (interaction) class_addProtocol(self, interaction);
}
- (instancetype)initWithDelegate:(id)delegate { (void)delegate; return [super init]; }
- (id)view { return _view; }
- (void)willMoveToView:(id)view { (void)view; }
- (void)didMoveToView:(id)view { _view = view; }
- (void)invalidate {}
@end

@interface UIPointerRegion : NSObject
@end
@implementation UIPointerRegion
+ (instancetype)regionWithRect:(CGRect)rect identifier:(id)identifier { (void)rect; (void)identifier; return nil; }
@end

@interface UIPointerStyle : NSObject
@end
@implementation UIPointerStyle
+ (instancetype)hiddenPointerStyle { return nil; }
@end

/// SDL decides the display's orientation from -[UIApplication statusBarOrientation], which
/// tvOS doesn't have (so it reads as portrait and swaps the TV's width and height, and
/// Ren'Py 7 then draws off screen). A TV is always landscape.
@interface ShioriTVOrientation : NSObject
@end
@implementation ShioriTVOrientation
+ (void)load {
    Class application = objc_getClass("UIApplication");
    IMP landscape = imp_implementationWithBlock(^NSInteger(id app) { (void)app; return 3; /* UIInterfaceOrientationLandscapeRight */ });
    class_replaceMethod(application, sel_registerName("statusBarOrientation"), landscape, "q@:");
}
@end

/// Ren'Py's iOS code keeps save tokens and its upgrade marker in the Documents folder, which
/// an Apple TV app can't write to: Documents lookups answer Caches/Documents instead (where
/// the hub keeps games on tvOS, URL.shioriDocuments).
@interface ShioriTVDocuments : NSObject
@end
@implementation ShioriTVDocuments
+ (void)load {
    Method method = class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:));
    NSArray<NSURL *> *(*original)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask) = (void *)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^NSArray<NSURL *> *(NSFileManager *manager, NSSearchPathDirectory directory, NSSearchPathDomainMask domains) {
        if (directory != NSDocumentDirectory) return original(manager, @selector(URLsForDirectory:inDomains:), directory, domains);
        NSURL *caches = original(manager, @selector(URLsForDirectory:inDomains:), NSCachesDirectory, domains).lastObject;
        NSURL *documents = [caches URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        [manager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:nil];
        return documents ? @[documents] : @[];
    }));
}
@end
