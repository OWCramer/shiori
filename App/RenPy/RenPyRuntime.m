#import "RenPyRuntime.h"

@import UIKit;
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static int running = 0;

typedef struct SDL_Window SDL_Window;

/// The loaded runtime framework (RenPy8 or RenPy7). Each one bundles CPython, Ren'Py's
/// compiled modules and SDL2, so only one can be in a process; VN Hub exits after a game.
static struct {
    void *handle;
    // From librenpython (renpy-build runtime/librenpython{2,3}.c). Finds the Python home at
    // dirname(argv[0])/base/lib/pythonX.Y and runs dirname(argv[0])/base/<basename(argv[0])>.py.
    int (*launcherMain)(int, char **);
    // SDL normally owns main() via SDL_UIKitRunApp; we start it ourselves.
    void (*setMainReady)(void);
    void (*willResignActive)(void);
    void (*didEnterBackground)(void);
    void (*willEnterForeground)(void);
    void (*didBecomeActive)(void);
    SDL_Window *(*currentWindow)(void);
    // Wrappers in runtime_shim.c around SDL's hidden event-injection functions.
    int (*sendKey)(unsigned char state, int scancode);
    int (*sendMouseMotion)(SDL_Window *window, int x, int y);
    int (*sendMouseButton)(SDL_Window *window, unsigned char state, unsigned char button);
} sdl;

static BOOL LoadRuntime(const char *name) {
    if (sdl.handle) return YES;
    NSString *path = [NSString stringWithFormat:@"%@/%s.framework/%s", NSBundle.mainBundle.privateFrameworksPath, name, name];
    sdl.handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!sdl.handle) {
        NSLog(@"VN Hub: couldn't load %s: %s", name, dlerror());
        return NO;
    }
    sdl.launcherMain = dlsym(sdl.handle, "launcher_main");
    sdl.setMainReady = dlsym(sdl.handle, "SDL_SetMainReady");
    sdl.willResignActive = dlsym(sdl.handle, "SDL_OnApplicationWillResignActive");
    sdl.didEnterBackground = dlsym(sdl.handle, "SDL_OnApplicationDidEnterBackground");
    sdl.willEnterForeground = dlsym(sdl.handle, "SDL_OnApplicationWillEnterForeground");
    sdl.didBecomeActive = dlsym(sdl.handle, "SDL_OnApplicationDidBecomeActive");
    sdl.currentWindow = dlsym(sdl.handle, "SDL_GL_GetCurrentWindow");
    sdl.sendKey = dlsym(sdl.handle, "vnhub_sdl_send_key");
    sdl.sendMouseMotion = dlsym(sdl.handle, "vnhub_sdl_send_mouse_motion");
    sdl.sendMouseButton = dlsym(sdl.handle, "vnhub_sdl_send_mouse_button");
    return sdl.launcherMain && sdl.setMainReady;
}

enum { ScancodeH = 11, ScancodeEscape = 41, ScancodeReturn = 40 };

static void PressKey(int scancode) {
    if (!sdl.sendKey) return;
    sdl.sendKey(1, scancode);
    sdl.sendKey(0, scancode);
}

/// Touch gestures from the spec, on top of Ren'Py's own touch handling (tap advances):
/// two-finger tap opens the game menu (Escape), long-press hides the text box (`h`).
/// Both delay touches until they fail, so a recognised gesture never also reaches the
/// game as a click, which would advance the dialogue.
@interface VNHubGestures : NSObject
@end

@implementation VNHubGestures

+ (instancetype)shared {
    static VNHubGestures *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [VNHubGestures new]; });
    return shared;
}

- (void)attachToWindow:(UIWindow *)window {
    UITapGestureRecognizer *menu = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openMenu:)];
    menu.numberOfTouchesRequired = 2;
    menu.delaysTouchesBegan = YES;
    [window addGestureRecognizer:menu];

    UILongPressGestureRecognizer *hide = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hideText:)];
    hide.minimumPressDuration = 0.45; // Just ahead of Ren'Py's own 0.5 s long-press.
    hide.delaysTouchesBegan = YES;
    [window addGestureRecognizer:hide];
}

- (void)openMenu:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized) PressKey(ScancodeEscape);
}

- (void)hideText:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) PressKey(ScancodeH);
}

@end

#if DEBUG
/// Replays input from the `VNHUB_INPUT` environment variable: `;`-separated steps of
/// `<seconds>:<x>,<y>` (tap at window points), `<seconds>:esc`, `:enter` or `:h`,
/// timed from game start. Simulator testing only.
static void ScheduleScriptedInput(void) {
    const char *script = getenv("VNHUB_INPUT");
    if (!script) return;
    NSArray<NSString *> *steps = [@(script) componentsSeparatedByString:@";"];
    for (NSString *step in steps) {
        NSArray<NSString *> *parts = [step componentsSeparatedByString:@":"];
        if (parts.count != 2) continue;
        double delay = parts[0].doubleValue;
        NSString *action = parts[1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SDL_Window *window = sdl.currentWindow ? sdl.currentWindow() : NULL;
            if (!window || !sdl.sendMouseMotion || !sdl.sendMouseButton) return;
            NSLog(@"VN Hub input: %@", action);
            if ([action isEqualToString:@"esc"] || [action isEqualToString:@"enter"] || [action isEqualToString:@"h"]) {
                PressKey([action isEqualToString:@"esc"] ? ScancodeEscape : [action isEqualToString:@"h"] ? ScancodeH : ScancodeReturn);
                return;
            }
            NSArray<NSString *> *xy = [action componentsSeparatedByString:@","];
            if (xy.count != 2) return;
            sdl.sendMouseMotion(window, xy[0].intValue, xy[1].intValue);
            sdl.sendMouseButton(window, 1, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                sdl.sendMouseButton(window, 0, 1);
            });
        });
    }
}
#endif

/// SDL's window for the running game.
static __weak UIWindow *gameWindow;
static void HideHubWindows(void);
static void RestoreGameLayout(void);
static void FitGameViews(void);

static UIWindowScene *ActiveWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

/// SDL 2.0.20 creates its UIWindow with -initWithFrame:, which in a scene-based app
/// (SwiftUI) gives a window attached to no scene, so it never appears. Give SDL's window
/// class an -initWithFrame: that attaches it to the active scene instead, and add the
/// touch gestures while we're there.
static void AttachSDLWindowsToScene(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class sdlWindow = NSClassFromString(@"SDL_uikitwindow");
        if (!sdlWindow) return;
        IMP sceneInit = class_getMethodImplementation(UIWindow.class, @selector(initWithWindowScene:));
        IMP frameInit = class_getMethodImplementation(UIWindow.class, @selector(initWithFrame:));
        IMP replacement = imp_implementationWithBlock(^id(UIWindow *self, CGRect frame) {
            UIWindowScene *scene = ActiveWindowScene();
            UIWindow *window = scene
                ? ((id (*)(id, SEL, UIWindowScene *))sceneInit)(self, @selector(initWithWindowScene:), scene)
                : ((id (*)(id, SEL, CGRect))frameInit)(self, @selector(initWithFrame:), frame);
            [[VNHubGestures shared] attachToWindow:window];
            gameWindow = window;
            // Once SDL has shown it, keep the hub's own window from showing through.
            dispatch_async(dispatch_get_main_queue(), ^{ HideHubWindows(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ FitGameViews(); });
            return window;
        });
        const char *types = method_getTypeEncoding(class_getInstanceMethod(UIWindow.class, @selector(initWithFrame:)));
        if (!class_addMethod(sdlWindow, @selector(initWithFrame:), replacement, types)) {
            class_replaceMethod(sdlWindow, @selector(initWithFrame:), replacement, types);
        }
    });
}

/// While a game runs it is the only thing on screen: hide the SwiftUI window, which would
/// otherwise show beside or through SDL's after a rotation.
static void HideHubWindows(void) {
    UIWindow *game = gameWindow;
    if (!game || !game.windowScene) return;
    for (UIWindow *window in game.windowScene.windows) {
        if (window != game) window.hidden = YES;
    }
}

/// Visual novels are landscape; ask the scene to rotate rather than letterboxing a
/// 16:9 game into a portrait phone screen.
static void RequestLandscape(void) {
    UIWindowScene *scene = ActiveWindowScene();
    if (!scene) return;
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:nil];
    }
}

/// Makes SDL's views track the window. When the app returns to the foreground Ren'Py
/// rebuilds its GL context, and SDL creates a fresh GL view sized to whatever the window
/// was at that instant (often the portrait background snapshot) with no autoresizing, so
/// it stays portrait-sized in a landscape window and ignores later rotations.
static void FitGameViews(void) {
    UIWindow *window = gameWindow;
    if (!window.windowScene) return;
    CGRect bounds = window.windowScene.coordinateSpace.bounds;
    if (!CGRectEqualToRect(window.frame, bounds)) window.frame = bounds;
    // SDL makes its GL view the view controller's root view. When it's recreated in the
    // background, UIKit leaves it at the portrait size inside the landscape container.
    UIView *root = window.rootViewController.view;
    UIView *container = root.superview ?: window;
    if (root && !CGRectEqualToRect(root.frame, container.bounds)) {
#if DEBUG
        NSLog(@"VN Hub layout: resizing %@ from %@ to %@", NSStringFromClass(root.class),
              NSStringFromCGRect(root.frame), NSStringFromCGRect(container.bounds));
#endif
        root.frame = container.bounds;
        root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // SDL tells Ren'Py about the new size from the view controller's layout pass.
        [root setNeedsLayout];
        [root layoutIfNeeded];
    }
    if (!window.isKeyWindow) [window makeKeyAndVisible];
}

/// Coming back from the Home Screen: ask for landscape again and refit SDL's views a few
/// times, since Ren'Py recreates its GL view shortly after the app becomes active.
static void RestoreGameLayout(void) {
    if (!gameWindow) return;
    RequestLandscape();
    HideHubWindows();
    for (NSNumber *delay in @[@0.0, @0.3, @0.8, @1.5, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ FitGameViews(); });
    }
}

int vnhub_renpy_run(const char *runtime, const char *gameFolder, const char *launcherName, const char *saveDirectory) {
    if (running) return -1;
    if (!LoadRuntime(runtime)) return -2;
    running = 1;

    AttachSDLWindowsToScene();
    RequestLandscape();
    // Coming back from the Home Screen (or Control Center, a call...) re-applies the layout.
    id activation = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *note) { RestoreGameLayout(); }];
    sdl.setMainReady();
#if DEBUG
    ScheduleScriptedInput();
#endif

    size_t length = strlen(gameFolder) + strlen(launcherName) + 2;
    char *argv0 = malloc(length);
    snprintf(argv0, length, "%s/%s", gameFolder, launcherName);

    char *argv[] = { argv0, "--savedir", (char *)saveDirectory, NULL };
    int status = sdl.launcherMain(3, argv);

    free(argv0);
    [NSNotificationCenter.defaultCenter removeObserver:activation];
    running = 0;
    return status;
}

int vnhub_renpy_is_running(void) { return running; }

void vnhub_renpy_will_resign_active(void) { if (running && sdl.willResignActive) sdl.willResignActive(); }
void vnhub_renpy_did_enter_background(void) { if (running && sdl.didEnterBackground) sdl.didEnterBackground(); }
void vnhub_renpy_will_enter_foreground(void) { if (running && sdl.willEnterForeground) sdl.willEnterForeground(); }
void vnhub_renpy_did_become_active(void) { if (running && sdl.didBecomeActive) sdl.didBecomeActive(); }
