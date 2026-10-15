// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#import "RenPyRuntime.h"

@import UIKit;
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static int running = 0;

typedef struct SDL_Window SDL_Window;

/// The loaded runtime framework (RenPy8 or RenPy7). Each one bundles CPython, Ren'Py's
/// compiled modules and SDL2, so only one can be in a process; Shiori exits after a game.
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
    // Controller input posted as SDL game-controller events (runtime_shim.c).
    int (*controllerButton)(int button, int down);
    int (*controllerAxis)(int axis, int value);
} sdl;

/// SDL's Objective-C class `name` as compiled into the loaded runtime. The KiriKiri engine
/// framework (linked at launch) carries its own SDL2 with the same class names, so a plain
/// NSClassFromString can return its copy, and hooking that one leaves Ren'Py's window
/// unattached and its frames unseen: the game runs, with sound, behind the cover.
static Class RuntimeClass(const char *name) {
    Dl_info info;
    if (!sdl.launcherMain || !dladdr((const void *)sdl.launcherMain, &info) || !info.dli_fname) {
        return objc_getClass(name);
    }
    char runtimePath[PATH_MAX];
    if (!realpath(info.dli_fname, runtimePath)) strlcpy(runtimePath, info.dli_fname, sizeof runtimePath);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    Class found = Nil;
    for (unsigned int i = 0; i < count && !found; i++) {
        if (strcmp(class_getName(classes[i]), name) != 0) continue;
        const char *image = class_getImageName(classes[i]);
        char imagePath[PATH_MAX];
        if (image && realpath(image, imagePath) && strcmp(imagePath, runtimePath) == 0) found = classes[i];
    }
    free(classes);
    if (!found) NSLog(@"Shiori: %s not found in %s; using the first one registered", name, runtimePath);
    return found ?: objc_getClass(name);
}

static BOOL LoadRuntime(const char *name) {
    if (sdl.handle) return YES;
    NSString *path = [NSString stringWithFormat:@"%@/%s.framework/%s", NSBundle.mainBundle.privateFrameworksPath, name, name];
    sdl.handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    // shiori_main2.py reaches GL through it (ctypes), to free Ren'Py 7's textures.
    setenv("SHIORI_RUNTIME_LIBRARY", path.fileSystemRepresentation, 1);
    if (!sdl.handle) {
        const char *reason = dlerror();
        NSLog(@"Shiori: couldn't load %s: %s", name, reason);
        // Into the session note (RenPyEngine.launch reads last_error.txt from the cache).
        const char *cache = getenv("SHIORI_CACHE");
        if (cache) {
            NSString *path = [@(cache) stringByAppendingPathComponent:@"last_error.txt"];
            [[NSString stringWithFormat:@"Couldn't load %s: %s", name, reason ?: "unknown"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
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
    sdl.controllerButton = dlsym(sdl.handle, "vnhub_sdl_controller_button");
    sdl.controllerAxis = dlsym(sdl.handle, "vnhub_sdl_controller_axis");
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
static double FootprintMB(void);

/// Whether a trackpad or mouse is driving the game right now: the pointer hovering over it
/// turns this on, a finger on the screen turns it off. The Python bootstrap reads it to show
/// the game's own cursor (config.mouse) as Ren'Py's software cursor, which also hides the
/// iPad pointer. Exported for ctypes.
static int pointerActive;
__attribute__((visibility("default"), used)) int shiori_renpy_pointer_active(void) { return pointerActive; }

/// A gesture the game's own keymap carries out, taken by the Python bootstrap's periodic
/// callback (`_gestures` in shiori_main.py): 1 skip (toggle_skip), 2 auto (toggle_afm), 3 the
/// backlog (the game's history screen), 4 leave (the game's own quit, config.quit_action).
/// Exported for ctypes.
static volatile int pendingGesture;
__attribute__((visibility("default"), used)) int shiori_renpy_take_gesture(void) {
    int gesture = pendingGesture;
    pendingGesture = 0;
    return gesture;
}

static void QueueGesture(int gesture, NSString *name) {
    NSLog(@"Shiori gesture: %@", name);
    pendingGesture = gesture;
}

@interface ShioriGestures : NSObject <UIGestureRecognizerDelegate>
@end

@implementation ShioriGestures

+ (instancetype)shared {
    static ShioriGestures *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ShioriGestures new]; });
    return shared;
}

- (void)attachToWindow:(UIWindow *)window {
#if TARGET_OS_TV
    // The Siri Remote: SDL turns Select into Return and Menu into Escape (the game menu);
    // Play/Pause hides the text box.
    UITapGestureRecognizer *hide = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideTextPress:)];
    hide.allowedPressTypes = @[@(UIPressTypePlayPause)];
    [window addGestureRecognizer:hide];
#else
    UITapGestureRecognizer *menu = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openMenu:)];
    menu.numberOfTouchesRequired = 2;
    // Fingers only: a trackpad's clicks go straight to SDL as mouse buttons (right click
    // opens the game menu there), and a held click mustn't hide the text box.
    menu.allowedTouchTypes = @[@(UITouchTypeDirect)];
    menu.delaysTouchesBegan = YES;
    [window addGestureRecognizer:menu];

    UILongPressGestureRecognizer *hide = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hideText:)];
    hide.minimumPressDuration = 0.45; // Just ahead of Ren'Py's own 0.5 s long-press.
    hide.allowedTouchTypes = @[@(UITouchTypeDirect)];
    hide.delaysTouchesBegan = YES;
    [window addGestureRecognizer:hide];

    // The gestures every engine shares (spec, Touch): two-finger swipes right (skip), up
    // (auto) and down (the backlog), and a two-finger hold (leave). Two fingers, because a
    // one-finger swipe is the game's (Ren'Py drags viewports and sliders), and multi-finger
    // sequences never reach SDL (FilterMultiFingerTouches). The game menu's tap waits for
    // them to fail, which they do as soon as the fingers lift without moving.
    UILongPressGestureRecognizer *leave = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(leave:)];
    leave.numberOfTouchesRequired = 2;
    leave.minimumPressDuration = 0.8;
    leave.allowedTouchTypes = @[@(UITouchTypeDirect)];
    leave.delaysTouchesBegan = YES;
    [window addGestureRecognizer:leave];
    [menu requireGestureRecognizerToFail:leave];
    NSArray *swipes = @[@[@(UISwipeGestureRecognizerDirectionRight), NSStringFromSelector(@selector(skip:))],
                        @[@(UISwipeGestureRecognizerDirectionUp), NSStringFromSelector(@selector(autoForward:))],
                        @[@(UISwipeGestureRecognizerDirectionDown), NSStringFromSelector(@selector(history:))]];
    for (NSArray *entry in swipes) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:NSSelectorFromString(entry[1])];
        swipe.direction = [entry[0] unsignedIntegerValue];
        swipe.numberOfTouchesRequired = 2;
        swipe.allowedTouchTypes = @[@(UITouchTypeDirect)];
        swipe.delaysTouchesBegan = YES;
        [window addGestureRecognizer:swipe];
        [menu requireGestureRecognizerToFail:swipe];
    }

    UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hovered:)];
    hover.delegate = self;
    [window addGestureRecognizer:hover];
    // Notices a finger without taking it from the game.
    UILongPressGestureRecognizer *finger = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(fingerDown:)];
    finger.minimumPressDuration = 0;
    finger.cancelsTouchesInView = NO;
    finger.delaysTouchesEnded = NO;
    finger.allowedTouchTypes = @[@(UITouchTypeDirect)];
    finger.delegate = self;
    [window addGestureRecognizer:finger];
#endif
}

#if !TARGET_OS_TV
- (void)hovered:(UIHoverGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan || recognizer.state == UIGestureRecognizerStateChanged) pointerActive = 1;
}

- (void)fingerDown:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) pointerActive = 0;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}
#endif

- (void)hideTextPress:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized) PressKey(ScancodeH);
}

- (void)openMenu:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized) {
        NSLog(@"Shiori gesture: game menu (%.0f MB)", FootprintMB());
        PressKey(ScancodeEscape);
    }
}

- (void)skip:(UISwipeGestureRecognizer *)recognizer { QueueGesture(1, @"skip"); }
- (void)autoForward:(UISwipeGestureRecognizer *)recognizer { QueueGesture(2, @"auto"); }
- (void)history:(UISwipeGestureRecognizer *)recognizer { QueueGesture(3, @"backlog"); }

- (void)leave:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) QueueGesture(4, @"leave (the game's quit)");
}

- (void)hideText:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        NSLog(@"Shiori gesture: hide text (%.0f MB)", FootprintMB());
        PressKey(ScancodeH);
    }
}

@end

#if DEBUG
/// Replays input from the `SHIORI_INPUT` environment variable: `;`-separated steps of
/// `<seconds>:<x>,<y>` (tap at window points), `<seconds>:esc`, `:enter`, `:h`, `:padN`, or a
/// shared gesture (`:skip`, `:auto`, `:history`, `:quit`),
/// timed from game start. Simulator testing only.
static void ScheduleScriptedInput(void) {
    const char *script = getenv("SHIORI_INPUT");
    if (!script) return;
    NSArray<NSString *> *steps = [@(script) componentsSeparatedByString:@";"];
    for (NSString *step in steps) {
        NSArray<NSString *> *parts = [step componentsSeparatedByString:@":"];
        if (parts.count != 2) continue;
        double delay = parts[0].doubleValue;
        NSString *action = parts[1];
        // Run-loop timers, not the main queue: while Ren'Py runs, SDL turns the run loop
        // itself, and main-queue blocks stop being serviced after the first.
        NSTimer *timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
            NSLog(@"Shiori input: %@", action);
            if ([action hasPrefix:@"pad"]) {
                int button = [action substringFromIndex:3].intValue;
                shiori_renpy_controller_button(button, 1);
                NSTimer *release = [NSTimer timerWithTimeInterval:0.08 repeats:NO block:^(NSTimer *r) {
                    shiori_renpy_controller_button(button, 0);
                }];
                [NSRunLoop.mainRunLoop addTimer:release forMode:NSRunLoopCommonModes];
                return;
            }
            // `skip`, `auto`, `history`, `quit`: the shared gestures, as if swiped or held.
            NSDictionary *gestures = @{@"skip": @1, @"auto": @2, @"history": @3, @"quit": @4};
            if (gestures[action]) {
                QueueGesture([gestures[action] intValue], action);
                return;
            }
            if ([action isEqualToString:@"esc"] || [action isEqualToString:@"enter"] || [action isEqualToString:@"h"]) {
                PressKey([action isEqualToString:@"esc"] ? ScancodeEscape : [action isEqualToString:@"h"] ? ScancodeH : ScancodeReturn);
                return;
            }
            // Taps need SDL's window, which is only "current" while Ren'Py draws.
            SDL_Window *window = sdl.currentWindow ? sdl.currentWindow() : NULL;
            if (!window || !sdl.sendMouseMotion || !sdl.sendMouseButton) return;
            NSArray<NSString *> *xy = [action componentsSeparatedByString:@","];
            if (xy.count != 2) return;
            sdl.sendMouseMotion(window, xy[0].intValue, xy[1].intValue);
            sdl.sendMouseButton(window, 1, 1);
            NSTimer *release = [NSTimer timerWithTimeInterval:0.08 repeats:NO block:^(NSTimer *r) {
                sdl.sendMouseButton(window, 0, 1);
            }];
            [NSRunLoop.mainRunLoop addTimer:release forMode:NSRunLoopCommonModes];
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
}
#endif

/// SDL's window for the running game.
static __weak UIWindow *gameWindow;
static void HideHubWindows(void);

/// The app's memory footprint in MB, for the console log.
static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / 1048576.0;
}

// MARK: - Exit tracing

/// Something inside the runtime can end the process with exit() while a game runs, with
/// no crash report and no Python error. Record who: the native stack (image + offset per
/// frame, to symbolicate with atos) goes to <cache>/native-exit.txt.
static void TraceNativeExit(void) {
    const char *cache = getenv("SHIORI_CACHE");
    if (!cache) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/native-exit.txt", cache);
    FILE *file = fopen(path, "w");
    if (!file) return;
    time_t now = time(NULL);
    fprintf(file, "exit() at %s", ctime(&now));
    void *frames[96];
    int count = backtrace(frames, 96);
    for (int i = 0; i < count; i++) {
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_fname) {
            const char *image = strrchr(info.dli_fname, '/');
            fprintf(file, "%2d %-28s base %p offset 0x%lx %s\n", i, image ? image + 1 : info.dli_fname, info.dli_fbase,
                    (unsigned long)((char *)frames[i] - (char *)info.dli_fbase), info.dli_sname ?: "?");
        } else {
            fprintf(file, "%2d %p\n", i, frames[i]);
        }
    }
    fclose(file);
}

static char signalPath[1024];

/// Notes a terminating signal that crash reports don't cover (async-signal-safe calls
/// only), then lets it take its default course. SIGPIPE is noted and ignored.
static void TraceSignal(int sig) {
    int file = open(signalPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (file >= 0) {
        char line[64];
        int length = snprintf(line, sizeof line, "signal %d\n", sig);
        write(file, line, (size_t)length);
        close(file);
    }
    if (sig == SIGPIPE) return;
    signal(sig, SIG_DFL);
    raise(sig);
}

static void TraceExitsWhilePlaying(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        atexit(TraceNativeExit);
        const char *cache = getenv("SHIORI_CACHE");
        if (cache) snprintf(signalPath, sizeof signalPath, "%s/signals.txt", cache);
        int signals[] = {SIGPIPE, SIGTERM, SIGHUP, SIGINT, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM, SIGXCPU, SIGXFSZ, SIGSYS};
        for (size_t i = 0; i < sizeof signals / sizeof *signals; i++) signal(signals[i], TraceSignal);
    });
    char path[1024];
    const char *cache = getenv("SHIORI_CACHE");
    if (cache) {
        snprintf(path, sizeof path, "%s/native-exit.txt", cache);
        unlink(path);
    }
}

// MARK: - Multi-finger touches

/// Touches SDL has already been given, and whether the current sequence ever had two or
/// more fingers down.
static NSMutableSet<UITouch *> *forwardedTouches;
static BOOL multiFingerSequence;

/// Keeps multi-finger touches away from the game. Two fingers are Shiori's game-menu
/// gesture; when the tap recognizer gives up on one (fingers held, moved, or landing
/// apart, as happens when it's tapped repeatedly), iOS delivers the held-back touches to
/// SDL, which turns them into a click wherever the first finger was. In the game menu
/// that can be Quit, then Yes. Any sequence that has two fingers down at once is
/// swallowed instead; touches SDL already had are cancelled, as UIKit itself would.
/// SDL slides its view up so the text field sits above the on-screen keyboard. Ren'Py's text
/// rectangle isn't in the view's points, so on a landscape phone the slide pushed the whole
/// game off screen (DDLC's name entry showed only black). Keep SDL's slide, but never more
/// than the keyboard's height: the game's lower half stays visible just above it.
static void LimitKeyboardSlide(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class controller = RuntimeClass("SDL_uikitviewcontroller");
        Method method = controller ? class_getInstanceMethod(controller, @selector(updateKeyboard)) : NULL;
        if (!method) return;
        IMP original = method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(UIViewController *self) {
            ((void (*)(id, SEL))original)(self, @selector(updateKeyboard));
            CGFloat keyboard = 0;
            @try {
                keyboard = [[self valueForKey:@"keyboardHeight"] doubleValue];
            } @catch (NSException *exception) {
                return;
            }
            CGAffineTransform transform = self.view.transform;
            const CGFloat limited = MIN(0, MAX(transform.ty, -keyboard));
#if DEBUG
            NSLog(@"Shiori keyboard: height %.0f, SDL slide %.0f, kept %.0f", keyboard, transform.ty, limited);
#endif
            if (limited != transform.ty) {
                transform.ty = limited;
                self.view.transform = transform;
            }
        }));
    });
}

/// Asks iOS for a steady 60 Hz while a game runs. Ren'Py paces itself and presents through
/// ANGLE without a display link, so a 120 Hz iPhone ran its screen at 48 Hz, and Ren'Py's
/// 60 fps frames alternated between 16.7 and 20.8 ms (KiriKiri's view had the same problem).
@interface ShioriFramePacer : NSObject
@end

@implementation ShioriFramePacer
- (void)tick:(CADisplayLink *)link {}
@end

static void RequestSteadyFrameRate(void) {
    static CADisplayLink *link;
    if (link) return;
    link = [CADisplayLink displayLinkWithTarget:[ShioriFramePacer new] selector:@selector(tick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

static void FilterMultiFingerTouches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class view = RuntimeClass("SDL_uikitview");
        if (!view) return;
        forwardedTouches = [NSMutableSet set];
        SEL cancelled = @selector(touchesCancelled:withEvent:);
        IMP originalCancelled = method_getImplementation(class_getInstanceMethod(view, cancelled));
        for (NSString *name in @[@"touchesBegan:withEvent:", @"touchesMoved:withEvent:",
                                 @"touchesEnded:withEvent:", @"touchesCancelled:withEvent:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod(view, selector);
            if (!method) continue;
            IMP original = method_getImplementation(method);
            BOOL began = [name hasPrefix:@"touchesBegan"];
            BOOL finishing = [name hasPrefix:@"touchesEnded"] || [name hasPrefix:@"touchesCancelled"];
            method_setImplementation(method, imp_implementationWithBlock(^(UIView *self, NSSet<UITouch *> *touches, UIEvent *event) {
                // Count every finger in the event, lifted or not: touches the tap recognizer
                // held back arrive late, sometimes already ended.
                NSSet<UITouch *> *all = event.allTouches;
                if (all.count >= 2 && !multiFingerSequence) {
                    multiFingerSequence = YES;
                    NSLog(@"Shiori touches: swallowing a %lu-finger sequence (%lu already sent)",
                          (unsigned long)all.count, (unsigned long)forwardedTouches.count);
                    // End what SDL already started, so no finger is left "pressed".
                    if (forwardedTouches.count > 0) {
                        NSSet *started = [forwardedTouches copy];
                        [forwardedTouches removeAllObjects];
                        ((void (*)(id, SEL, NSSet *, UIEvent *))originalCancelled)(self, cancelled, started, event);
                    }
                }
                if (multiFingerSequence) {
                    // The sequence is over once every finger has lifted.
                    if (finishing) {
                        BOOL lifted = YES;
                        for (UITouch *touch in all) {
                            if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) lifted = NO;
                        }
                        if (lifted) multiFingerSequence = NO;
                    }
                    return;
                }
                if (began) [forwardedTouches unionSet:touches];
                if (finishing) [forwardedTouches minusSet:touches];
                ((void (*)(id, SEL, NSSet *, UIEvent *))original)(self, selector, touches, event);
            }));
        }
    });
}

// MARK: - Launch cover

static UIWindowScene *ActiveWindowScene(void);

/// Landscape, no status bar or home indicator, like the game that follows.
@interface ShioriCoverController : UIViewController
@end

@implementation ShioriCoverController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

static UIWindow *coverWindow;
static BOOL coverLeaving;

/// Fades the cover out (once) and drops its window.
static void DismissCover(void) {
    if (!coverWindow || coverLeaving) return;
    coverLeaving = YES;
    UIWindow *window = coverWindow;
    [UIView animateWithDuration:0.45 delay:0.2 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        window.alpha = 0;
    } completion:^(BOOL finished) {
        window.hidden = YES;
        if (coverWindow == window) coverWindow = nil;
    }];
}

/// The game's banner art, logo and a spinner, from the moment Play hands over until Ren'Py
/// draws its first real frame. Paths come from SHIORI_COVER_HERO / _LOGO (Swift fetches
/// them while saves sync); without them, the game's name on black.
static void ShowCover(void) {
    UIWindowScene *scene = ActiveWindowScene();
    if (!scene) return;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelNormal + 10;
    window.userInteractionEnabled = NO;
    window.backgroundColor = UIColor.blackColor;
    ShioriCoverController *controller = [ShioriCoverController new];
    window.rootViewController = controller;
    UIView *root = controller.view;
    root.backgroundColor = UIColor.blackColor;

    const char *heroPath = getenv("SHIORI_COVER_HERO");
    UIImage *hero = heroPath ? [UIImage imageWithContentsOfFile:@(heroPath)] : nil;
    if (hero) {
        UIImageView *art = [[UIImageView alloc] initWithImage:hero];
        art.frame = root.bounds;
        art.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        art.contentMode = UIViewContentModeScaleAspectFill;
        art.clipsToBounds = YES;
        art.alpha = 0.55;
        [root addSubview:art];
    }

    const char *logoPath = getenv("SHIORI_COVER_LOGO");
    UIImage *logo = logoPath ? [UIImage imageWithContentsOfFile:@(logoPath)] : nil;
    UIView *mark;
    if (logo) {
        UIImageView *logoView = [[UIImageView alloc] initWithImage:logo];
        logoView.contentMode = UIViewContentModeScaleAspectFit;
        logoView.layer.shadowColor = UIColor.blackColor.CGColor;
        logoView.layer.shadowOpacity = 0.6;
        logoView.layer.shadowRadius = 12;
        logoView.layer.shadowOffset = CGSizeMake(0, 4);
        mark = logoView;
    } else {
        UILabel *title = [UILabel new];
        const char *name = getenv("SHIORI_COVER_TITLE");
        title.text = name ? @(name) : @"";
        title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightHeavy];
        title.textColor = UIColor.whiteColor;
        title.textAlignment = NSTextAlignmentCenter;
        title.numberOfLines = 2;
        mark = title;
    }
    mark.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:mark];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor colorWithWhite:1 alpha:0.85];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [root addSubview:spinner];

    [NSLayoutConstraint activateConstraints:@[
        [mark.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [mark.centerYAnchor constraintEqualToAnchor:root.centerYAnchor constant:-16],
        [mark.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor multiplier:0.5],
        [mark.heightAnchor constraintLessThanOrEqualToAnchor:root.heightAnchor multiplier:0.36],
        [spinner.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:mark.bottomAnchor constant:28],
    ]];
    if (logo) {
        // Keep the logo's proportions inside those limits.
        NSLayoutConstraint *aspect = [mark.widthAnchor constraintEqualToAnchor:mark.heightAnchor
                                                                    multiplier:logo.size.width / MAX(logo.size.height, 1)];
        NSLayoutConstraint *wide = [mark.widthAnchor constraintEqualToAnchor:root.widthAnchor multiplier:0.5];
        wide.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[aspect, wide]];
    }

    window.hidden = NO;
    coverWindow = window;
    coverLeaving = NO;
    // Whatever happens, don't hide the game for long. A run-loop timer: SDL's event loop runs
    // the main run loop, which fires timers even when it doesn't get to the main queue.
    NSTimer *fallback = [NSTimer timerWithTimeInterval:12 repeats:NO block:^(NSTimer *timer) { DismissCover(); }];
    [NSRunLoop.mainRunLoop addTimer:fallback forMode:NSRunLoopCommonModes];
}

/// Lets the turn to landscape finish before Python starts: Python blocks the main thread
/// for a second or two, which would freeze the rotation halfway.
static void FinishRotation(void) {
#if TARGET_OS_TV
    [CATransaction flush]; // A TV doesn't rotate.
#else
    UIWindowScene *scene = ActiveWindowScene();
    // Already landscape (an iPad on its side): nothing is animating.
    if (UIInterfaceOrientationIsLandscape(scene.effectiveGeometry.interfaceOrientation)) {
        [CATransaction flush];
        return;
    }
    CFTimeInterval start = CACurrentMediaTime(), landscapeAt = 0;
    while (CACurrentMediaTime() - start < 1.5) {
        BOOL landscape = UIInterfaceOrientationIsLandscape(scene.effectiveGeometry.interfaceOrientation);
        if (landscape && landscapeAt == 0) landscapeAt = CACurrentMediaTime();
        // Otherwise give the rotation animation time to play out.
        if (landscapeAt > 0 && CACurrentMediaTime() - landscapeAt > 0.45) break;
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    [CATransaction flush];
#endif
}

typedef void (*ReadPixelsFunction)(int, int, int, int, unsigned, unsigned, void *);

/// Whether the frame about to be presented has something other than black in it, from a
/// row across the middle (letterbox bars are at the sides or the top and bottom).
static BOOL FrameHasContent(UIView *view) {
    static ReadPixelsFunction readPixels;
    if (!readPixels) readPixels = (ReadPixelsFunction)dlsym(RTLD_DEFAULT, "glReadPixels");
    if (!readPixels || ![view respondsToSelector:@selector(backingWidth)]) return NO;
    int width = ((int (*)(id, SEL))objc_msgSend)(view, @selector(backingWidth));
    int height = ((int (*)(id, SEL))objc_msgSend)(view, @selector(backingHeight));
    if (width <= 0 || height <= 0) return NO;
    uint8_t *row = calloc((size_t)width, 4);
    readPixels(0, height / 2, width, 1, 0x1908 /* GL_RGBA */, 0x1401 /* GL_UNSIGNED_BYTE */, row);
    int lit = 0;
    for (int x = 0; x < width; x++) {
        uint8_t *p = row + x * 4;
        if (MAX(p[0], MAX(p[1], p[2])) > 24) lit++;
    }
    free(row);
    return lit > width / 20;
}

#if DEBUG
/// What the GPU device has allocated in this process: ANGLE (Ren'Py's OpenGL ES) draws
/// through the system default Metal device.
static double MetalAllocatedMB(void) {
    static id<MTLDevice> device;
    if (!device) device = MTLCreateSystemDefaultDevice();
    return device.currentAllocatedSize / 1048576.0;
}

/// Debug builds: frame timing every 5 seconds to <cache>/perf.txt, like KiriKiri's, so a
/// device run can be pulled and read. "interval" is swap to swap; "swap" is the time spent
/// presenting (GPU and display wait), the rest of each interval is Ren'Py's own work.
static void RecordFramePerf(double interval, double swap) {
    static double intervals[1024], swaps[1024];
    static int count;
    static CFTimeInterval windowStart;
    CFTimeInterval now = CACurrentMediaTime();
    if (windowStart == 0) windowStart = now;
    if (interval > 0 && count < 1024) {
        intervals[count] = interval;
        swaps[count] = swap;
        count++;
    }
    if (now - windowStart < 5 || count == 0) return;
    double sortedIntervals[1024], sortedSwaps[1024];
    memcpy(sortedIntervals, intervals, sizeof(double) * count);
    memcpy(sortedSwaps, swaps, sizeof(double) * count);
    qsort_b(sortedIntervals, count, sizeof(double), ^int(const void *a, const void *b) {
        double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; });
    qsort_b(sortedSwaps, count, sizeof(double), ^int(const void *a, const void *b) {
        double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; });
    double intervalSum = 0, swapSum = 0;
    int slow = 0;
    for (int i = 0; i < count; i++) {
        intervalSum += intervals[i];
        swapSum += swaps[i];
        if (intervals[i] > 17.5) slow++;
    }
    const char *cache = getenv("SHIORI_CACHE");
    if (cache) {
        char path[1024];
        snprintf(path, sizeof path, "%s/perf.txt", cache);
        FILE *file = fopen(path, "a");
        if (file) {
            NSString *time = [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle];
            fprintf(file, "%s interval avg %.1f p50 %.1f p95 %.1f max %.1f >17.5ms %d | swap avg %.1f p50 %.1f p95 %.1f max %.1f | frames %d | %.0f MB, Metal %.0f MB\n",
                    time.UTF8String, intervalSum / count, sortedIntervals[count / 2],
                    sortedIntervals[(int)(count * 0.95)], sortedIntervals[count - 1], slow,
                    swapSum / count, sortedSwaps[count / 2], sortedSwaps[(int)(count * 0.95)],
                    sortedSwaps[count - 1], count, FootprintMB(), MetalAllocatedMB());
            fclose(file);
        }
    }
    count = 0;
    windowStart = now;
}
#endif

/// Lifts the cover on the first frame with real content in it.
static void WatchForFirstFrame(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class glView = RuntimeClass("SDL_uikitopenglview");
        Method method = glView ? class_getInstanceMethod(glView, @selector(swapBuffers)) : NULL;
        if (!method) return;
        IMP original = method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(UIView *view) {
            static BOOL watching;
            if (!watching) {
                watching = YES;
                void (*watchInput)(void) = sdl.handle ? dlsym(sdl.handle, "vnhub_sdl_watch_input") : NULL;
                if (watchInput) watchInput();
                int (*hasFocus)(void) = sdl.handle ? dlsym(sdl.handle, "vnhub_sdl_has_keyboard_focus") : NULL;
                if (hasFocus) {
                    NSLog(@"Shiori SDL: keyboard focus %s at first frame", hasFocus() ? "set" : "NOT set");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        NSLog(@"Shiori SDL: keyboard focus %s after 5 s", hasFocus() ? "set" : "NOT set");
                    });
                }
            }
            if (coverWindow && !coverLeaving && FrameHasContent(view)) DismissCover();
#if DEBUG
            static CFTimeInterval lastSwap;
            CFTimeInterval swapStart = CACurrentMediaTime();
#endif
            ((void (*)(id, SEL))original)(view, @selector(swapBuffers));
#if DEBUG
            CFTimeInterval swapEnd = CACurrentMediaTime();
            RecordFramePerf(lastSwap > 0 ? (swapEnd - lastSwap) * 1000 : 0, (swapEnd - swapStart) * 1000);
            lastSwap = swapEnd;
#endif
        }));
    });
}

static void RestoreGameLayout(void);
static void FitGameViews(BOOL makeKey);

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
        Class sdlWindow = RuntimeClass("SDL_uikitwindow");
        if (!sdlWindow) return;
        IMP sceneInit = class_getMethodImplementation(UIWindow.class, @selector(initWithWindowScene:));
        IMP frameInit = class_getMethodImplementation(UIWindow.class, @selector(initWithFrame:));
        IMP replacement = imp_implementationWithBlock(^id(UIWindow *self, CGRect frame) {
            UIWindowScene *scene = ActiveWindowScene();
            UIWindow *window = scene
                ? ((id (*)(id, SEL, UIWindowScene *))sceneInit)(self, @selector(initWithWindowScene:), scene)
                : ((id (*)(id, SEL, CGRect))frameInit)(self, @selector(initWithFrame:), frame);
            [[ShioriGestures shared] attachToWindow:window];
            gameWindow = window;
            // Once SDL has shown it, keep the hub's own window from showing through.
            dispatch_async(dispatch_get_main_queue(), ^{ HideHubWindows(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ FitGameViews(YES); });
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
        if (window != game && window != coverWindow) window.hidden = YES;
    }
}

/// Visual novels are landscape; ask the scene to rotate rather than letterboxing a
/// 16:9 game into a portrait phone screen.
static void RequestLandscape(void) {
#if !TARGET_OS_TV
    UIWindowScene *scene = ActiveWindowScene();
    if (!scene) return;
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:nil];
    }
#endif
}

/// Makes SDL's views track the window. When the app returns to the foreground Ren'Py
/// rebuilds its GL context, and SDL creates a fresh GL view sized to whatever the window
/// was at that instant (often the portrait background snapshot) with no autoresizing, so
/// it stays portrait-sized in a landscape window and ignores later rotations.
static void FitGameViews(BOOL makeKey) {
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
        NSLog(@"Shiori layout: resizing %@ from %@ to %@", NSStringFromClass(root.class),
              NSStringFromCGRect(root.frame), NSStringFromCGRect(container.bounds));
#endif
        root.frame = container.bounds;
        root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // SDL tells Ren'Py about the new size from the view controller's layout pass.
        [root setNeedsLayout];
        [root layoutIfNeeded];
    }
    if (makeKey && !window.isKeyWindow) [window makeKeyAndVisible];
}

/// Coming back from the Home Screen: ask for landscape again and refit SDL's views.
static void RestoreGameLayout(void) {
    if (!gameWindow) return;
    RequestLandscape();
    HideHubWindows();
    FitGameViews(YES);
}

/// Keeps SDL's views fitted while a game runs. Ren'Py recreates its GL view shortly after
/// the app becomes active, and iPadOS resizes the window for the app switcher without the
/// app leaving the foreground; a view left at the old size drew the game small in a corner
/// until the next refit (the user, 2026-10-10). Four checks a second cost nothing when it fits.
static NSTimer *StartLayoutWatch(void) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        // Never takes key status here: the system keyboard or an alert may hold it.
        if (gameWindow) FitGameViews(NO);
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

int shiori_renpy_run(const char *runtime, const char *gameFolder, const char *launcherName, const char *saveDirectory) {
    if (running) return -1;
    if (!LoadRuntime(runtime)) return -2;
    running = 1;

    AttachSDLWindowsToScene();
    NSLog(@"Shiori memory: %.0f MB used, %.0f MB more available before the limit",
          FootprintMB(), os_proc_available_memory() / 1048576.0);
    WatchForFirstFrame();
    LimitKeyboardSlide();
    RequestSteadyFrameRate();
    FilterMultiFingerTouches();
    TraceExitsWhilePlaying();
    ShowCover();
    RequestLandscape();
    FinishRotation();
    // Coming back from the Home Screen (or Control Center, a call...) re-applies the layout.
    id activation = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *note) { RestoreGameLayout(); }];
    NSTimer *layoutWatch = StartLayoutWatch();
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
    [layoutWatch invalidate];
    running = 0;
    return status;
}

int shiori_renpy_is_running(void) { return running; }

void shiori_renpy_controller_button(int button, int down) {
    if (running && sdl.controllerButton) sdl.controllerButton(button, down);
}

void shiori_renpy_controller_axis(int axis, int value) {
    if (running && sdl.controllerAxis) sdl.controllerAxis(axis, value);
}

void shiori_renpy_restore_hub(void) {
    UIWindow *game = gameWindow;
    UIWindowScene *scene = game.windowScene ?: ActiveWindowScene();
    game.hidden = YES;
    coverWindow.hidden = YES;
    coverWindow = nil;
    for (UIWindow *window in scene.windows) {
        if (window != game && [window isKindOfClass:UIWindow.class] && !window.isKeyWindow) window.hidden = NO;
    }
    for (UIWindow *window in scene.windows) {
        if (window != game) { [window makeKeyAndVisible]; break; }
    }
}

void shiori_renpy_will_resign_active(void) { if (running && sdl.willResignActive) sdl.willResignActive(); }
void shiori_renpy_did_enter_background(void) { if (running && sdl.didEnterBackground) sdl.didEnterBackground(); }
void shiori_renpy_will_enter_foreground(void) { if (running && sdl.willEnterForeground) sdl.willEnterForeground(); }
void shiori_renpy_did_become_active(void) { if (running && sdl.didBecomeActive) sdl.didBecomeActive(); }
