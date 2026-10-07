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
