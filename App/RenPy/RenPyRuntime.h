// Starts an embedded Ren'Py runtime on a game folder in Documents, inside the running
// SwiftUI app. Runtimes are frameworks built by Scripts/build-renpy-runtimes.sh:
// "RenPy8" (Ren'Py 8.1.3, CPython 3.9) and "RenPy7" (Ren'Py 7.8.7, CPython 2.7).
#pragma once

/// Runs a Ren'Py game until it quits. Blocks the calling (main) thread; SDL keeps the
/// run loop turning, so UIKit stays responsive underneath.
///
/// `gameFolder` holds `base/` (Python home: `base/lib/python3.9`) and the launcher script
/// `base/<launcherName>.py`. Saves are written to `saveDirectory`.
/// Returns Python's exit status, or a negative value if the runtime couldn't be loaded.
int vnhub_renpy_run(const char *runtime, const char *gameFolder, const char *launcherName, const char *saveDirectory);

/// Forward app lifecycle changes to SDL while a game runs (SwiftUI owns the app delegate,
/// so SDL's own delegate never sees them).
void vnhub_renpy_will_resign_active(void);
void vnhub_renpy_did_enter_background(void);
void vnhub_renpy_will_enter_foreground(void);
void vnhub_renpy_did_become_active(void);

/// True while `vnhub_renpy_run` is executing.
int vnhub_renpy_is_running(void);
