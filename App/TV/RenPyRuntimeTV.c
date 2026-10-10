// The Ren'Py runtime on Apple TV: not built for tvOS yet (its CPython, SDL2 and MetalANGLE
// frameworks are iOS-only), so the hub's calls answer "not running" and a launch fails with
// a status the game page reports. Same interface as App/RenPy/RenPyRuntime.h.
#include "../RenPy/RenPyRuntime.h"

int shiori_renpy_run(const char *runtime, const char *gameFolder, const char *launcherName, const char *saveDirectory) {
    (void)runtime; (void)gameFolder; (void)launcherName; (void)saveDirectory;
    return -1;
}
void shiori_renpy_will_resign_active(void) {}
void shiori_renpy_did_enter_background(void) {}
void shiori_renpy_will_enter_foreground(void) {}
void shiori_renpy_did_become_active(void) {}
void shiori_renpy_restore_hub(void) {}
void shiori_renpy_controller_button(int button, int down) { (void)button; (void)down; }
void shiori_renpy_controller_axis(int axis, int value) { (void)axis; (void)value; }
int shiori_renpy_is_running(void) { return 0; }
