#import "RenPyRuntime.h"

@import UIKit;
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

// From librenpython.a (renpy-build runtime/librenpython3.c). Finds the Python home at
// dirname(argv[0])/base/lib/python3.9 and runs dirname(argv[0])/base/<basename(argv[0])>.py.
int launcher_main(int argc, char **argv);

// From libSDL2.a. SDL normally owns main() via SDL_UIKitRunApp; we start it ourselves.
void SDL_SetMainReady(void);
void SDL_OnApplicationWillResignActive(void);
void SDL_OnApplicationDidEnterBackground(void);
void SDL_OnApplicationWillEnterForeground(void);
void SDL_OnApplicationDidBecomeActive(void);

static int running = 0;

// SDL internals (non-static in libSDL2.a).
typedef struct SDL_Window SDL_Window;
SDL_Window *SDL_GL_GetCurrentWindow(void);
int SDL_SendKeyboardKey(unsigned char state, int scancode);

enum { ScancodeH = 11, ScancodeEscape = 41, ScancodeReturn = 40 };

static void PressKey(int scancode) {
    SDL_SendKeyboardKey(1, scancode);
    SDL_SendKeyboardKey(0, scancode);
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
int SDL_SendMouseMotion(SDL_Window *window, unsigned int mouseID, int relative, int x, int y);
int SDL_SendMouseButton(SDL_Window *window, unsigned int mouseID, unsigned char state, unsigned char button);

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
            SDL_Window *window = SDL_GL_GetCurrentWindow();
            if (!window) return;
            NSLog(@"VN Hub input: %@", action);
            if ([action isEqualToString:@"esc"] || [action isEqualToString:@"enter"] || [action isEqualToString:@"h"]) {
                PressKey([action isEqualToString:@"esc"] ? ScancodeEscape : [action isEqualToString:@"h"] ? ScancodeH : ScancodeReturn);
                return;
            }
            NSArray<NSString *> *xy = [action componentsSeparatedByString:@","];
            if (xy.count != 2) return;
            SDL_SendMouseMotion(window, 0, 0, xy[0].intValue, xy[1].intValue);
            SDL_SendMouseButton(window, 0, 1, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                SDL_SendMouseButton(window, 0, 0, 1);
            });
        });
    }
}
#endif

/// SDL's window for the running game.
static __weak UIWindow *gameWindow;
static void HideHubWindows(void);
static void RestoreGameLayout(void);

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

/// After a trip to the Home Screen the scene comes back in portrait first, and SDL's
/// window keeps that portrait frame once it turns landscape again, so the game draws in a
/// strip. Ask for landscape again and size the window to the scene once it has rotated.
static void RestoreGameLayout(void) {
    UIWindow *game = gameWindow;
    if (!game) return;
    RequestLandscape();
    HideHubWindows();
    for (NSNumber *delay in @[@0.0, @0.35, @0.9]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *window = gameWindow;
            if (!window.windowScene) return;
            CGRect bounds = window.windowScene.coordinateSpace.bounds;
            if (!CGRectEqualToRect(window.frame, bounds)) window.frame = bounds;
            if (!window.isKeyWindow) [window makeKeyAndVisible];
        });
    }
}

int vnhub_renpy_run(const char *gameFolder, const char *launcherName, const char *saveDirectory) {
    if (running) return -1;
    running = 1;

    AttachSDLWindowsToScene();
    RequestLandscape();
    // Coming back from the Home Screen (or Control Center, a call...) re-applies the layout.
    id activation = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *note) { RestoreGameLayout(); }];
    SDL_SetMainReady();
#if DEBUG
    ScheduleScriptedInput();
#endif

    size_t length = strlen(gameFolder) + strlen(launcherName) + 2;
    char *argv0 = malloc(length);
    snprintf(argv0, length, "%s/%s", gameFolder, launcherName);

    char *argv[] = { argv0, "--savedir", (char *)saveDirectory, NULL };
    int status = launcher_main(3, argv);

    free(argv0);
    [NSNotificationCenter.defaultCenter removeObserver:activation];
    running = 0;
    return status;
}

int vnhub_renpy_is_running(void) { return running; }

void vnhub_renpy_will_resign_active(void) { if (running) SDL_OnApplicationWillResignActive(); }
void vnhub_renpy_did_enter_background(void) { if (running) SDL_OnApplicationDidEnterBackground(); }
void vnhub_renpy_will_enter_foreground(void) { if (running) SDL_OnApplicationWillEnterForeground(); }
void vnhub_renpy_did_become_active(void) { if (running) SDL_OnApplicationDidBecomeActive(); }
