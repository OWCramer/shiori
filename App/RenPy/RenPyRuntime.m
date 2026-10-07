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

#if DEBUG
// SDL internals (non-static in libSDL2.a), used only to replay scripted input in testing.
typedef struct SDL_Window SDL_Window;
SDL_Window *SDL_GL_GetCurrentWindow(void);
int SDL_SendMouseMotion(SDL_Window *window, unsigned int mouseID, int relative, int x, int y);
int SDL_SendMouseButton(SDL_Window *window, unsigned int mouseID, unsigned char state, unsigned char button);
int SDL_SendKeyboardKey(unsigned char state, int scancode);

/// Replays input from the `VNHUB_INPUT` environment variable: `;`-separated steps of
/// `<seconds>:<x>,<y>` (tap at window points), `<seconds>:esc` or `<seconds>:enter`,
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
            if ([action isEqualToString:@"esc"] || [action isEqualToString:@"enter"]) {
                int scancode = [action isEqualToString:@"esc"] ? 41 : 40;
                SDL_SendKeyboardKey(1, scancode);
                SDL_SendKeyboardKey(0, scancode);
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
/// class an -initWithFrame: that attaches it to the active scene instead.
static void AttachSDLWindowsToScene(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class sdlWindow = NSClassFromString(@"SDL_uikitwindow");
        if (!sdlWindow) return;
        IMP sceneInit = class_getMethodImplementation(UIWindow.class, @selector(initWithWindowScene:));
        IMP frameInit = class_getMethodImplementation(UIWindow.class, @selector(initWithFrame:));
        IMP replacement = imp_implementationWithBlock(^id(UIWindow *self, CGRect frame) {
            UIWindowScene *scene = ActiveWindowScene();
            if (scene) {
                return ((id (*)(id, SEL, UIWindowScene *))sceneInit)(self, @selector(initWithWindowScene:), scene);
            }
            return ((id (*)(id, SEL, CGRect))frameInit)(self, @selector(initWithFrame:), frame);
        });
        const char *types = method_getTypeEncoding(class_getInstanceMethod(UIWindow.class, @selector(initWithFrame:)));
        if (!class_addMethod(sdlWindow, @selector(initWithFrame:), replacement, types)) {
            class_replaceMethod(sdlWindow, @selector(initWithFrame:), replacement, types);
        }
    });
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

int vnhub_renpy_run(const char *gameFolder, const char *launcherName, const char *saveDirectory) {
    if (running) return -1;
    running = 1;

    AttachSDLWindowsToScene();
    RequestLandscape();
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
    running = 0;
    return status;
}

int vnhub_renpy_is_running(void) { return running; }

void vnhub_renpy_will_resign_active(void) { if (running) SDL_OnApplicationWillResignActive(); }
void vnhub_renpy_did_enter_background(void) { if (running) SDL_OnApplicationDidEnterBackground(); }
void vnhub_renpy_will_enter_foreground(void) { if (running) SDL_OnApplicationWillEnterForeground(); }
void vnhub_renpy_did_become_active(void) { if (running) SDL_OnApplicationDidBecomeActive(); }
