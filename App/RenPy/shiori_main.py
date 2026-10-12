# Shiori's entry point for Ren'Py games. Ren'Py's iOS launcher runs this as main.py from a
# runner folder (Library/Caches/RenPy/<game>/runner/base/, whose lib/ links to the game's
# lib/), so it can set things up before handing over to the game's own launcher script.
#
# It keeps the game's base/ folder byte-identical to what Steam delivered, so verify stays
# meaningful: Python bytecode and Ren'Py's cache/ files are written under SHIORI_CACHE.
#
# It also layers the game's patch/game/ folder (SHIORI_PATCH_GAME) over base/game/: loose
# files and scripts there shadow the game's own, and archives (.rpa) in either folder are
# ordered as if they all sat in one game/ folder, as they would on PC.

import os
import sys
import runpy

GAME_BASE = os.environ["SHIORI_GAME_BASE"]
LAUNCHER = os.environ["SHIORI_LAUNCHER"]
CACHE = os.environ["SHIORI_CACHE"]
PATCH_GAME = os.environ.get("SHIORI_PATCH_GAME", "")


# --- Session record ------------------------------------------------------------------
# Game output (Python's and the runtime's) goes to <cache>/logs/console.txt, so a session
# that ends unexpectedly on a device can be read back afterwards through the app
# container. Redirected at the file-descriptor level: Ren'Py pickles its own state, and a
# replacement sys.stdout object would end up in that pickle. How the game ended goes to
# <cache>/exit.txt, from the bottom of this file.
import time as _time
import traceback as _traceback

_LOGS = os.path.join(CACHE, "logs")
if not os.path.isdir(_LOGS):
    os.makedirs(_LOGS)
try:
    os.remove(os.path.join(CACHE, "exit.txt"))
except OSError:
    pass
_console = os.path.join(_LOGS, "console.txt")
try:
    if os.path.getsize(_console) > 2000000:
        os.remove(_console)
except OSError:
    pass
try:
    sys.stdout.flush()
    sys.stderr.flush()
    _fd = os.open(_console, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(_fd, 1)
    os.dup2(_fd, 2)
    os.close(_fd)
except OSError:
    pass
print("\n===== Shiori session %s =====" % _time.ctime())
sys.stdout.flush()


def _record_exit(how):
    try:
        with open(os.path.join(CACHE, "exit.txt"), "w") as f:
            f.write("%s at %s\n" % (how, _time.ctime()))
            if sys.exc_info()[0] is not None:
                _traceback.print_exc(file=f)
            else:
                _traceback.print_stack(file=f)
    except Exception:
        pass


_MAIN_PID = os.getpid()
_real_os_exit = os._exit


def _os_exit(status):
    # Only the game's own process; forked children (subprocess) exit through here too.
    if os.getpid() == _MAIN_PID:
        _record_exit("os._exit(%r)" % (status,))
        try:
            sys.stdout.flush()
        except Exception:
            pass
    _real_os_exit(status)


os._exit = _os_exit

# Compiled .pyc files go to the cache instead of base/**/__pycache__.
sys.pycache_prefix = os.path.join(CACHE, "pycache")

sys.path.insert(0, GAME_BASE)

import renpy  # noqa: E402  (the game's own Ren'Py, from base/renpy)


def _cache_path(name):
    name = name.replace("\\", "/").lstrip("/")
    if name.startswith("cache/"):
        return os.path.join(CACHE, "game", name)
    return None


def _patch_renpy():
    """Runs right after Ren'Py's import_all(), once its modules exist."""
    loader = renpy.loader
    original_get_path = loader.get_path
    original_load = loader.load

    def get_path(fn):
        # Ren'Py writes bytecode, screen, shader and imagemap caches through this.
        path = _cache_path(fn)
        if path is None:
            return original_get_path(fn)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return path

    def load(name, directory=None, tl=True):
        # Prefer our cache copy; fall back to the one the game shipped in game/cache.
        path = _cache_path(name)
        if path is not None and os.path.exists(path):
            return open(path, "rb")
        return original_load(name, directory=directory, tl=tl)

    loader.get_path = get_path
    loader.load = load

    # Gamepad diagnostics: whether Ren'Py sees a controller and gets its events.
    controller = renpy.display.controller
    original_init = controller.init
    original_start = controller.start
    original_post = controller.post_event
    logged = [0]

    def _say(text):
        print("Shiori pad: " + text)
        sys.stdout.flush()

    def init():
        original_init()
        try:
            import pygame_sdl2
            _say("init, pad_enabled=%r, controllers=%r, joysticks=%r" % (
                renpy.game.preferences.pad_enabled, pygame_sdl2.controller.get_count(),
                pygame_sdl2.joystick.get_count()))
        except Exception as e:
            _say("init (%r)" % (e,))

    def start(index):
        _say("start %r" % (index,))
        return original_start(index)

    def post_event(control, state, repeat):
        if logged[0] < 60 and not repeat:
            logged[0] += 1
            _say("%s %s focused=%r" % (control, state, renpy.display.interface.keyboard_focused))
        return original_post(control, state, repeat)

    ticks = [0]

    def report_focus():
        ticks[0] += 1
        if ticks[0] in (100, 600):
            _say("keyboard_focused=%r mouse_focused=%r" % (
                renpy.display.interface.keyboard_focused, getattr(renpy.display.interface, "mouse_focused", None)))

    renpy.config.periodic_callbacks.append(report_focus)
    controller.init = init
    controller.start = start
    controller.post_event = post_event

    # bootstrap sets config.logdir to the game's base folder just before main();
    # log.txt and traceback.txt go to the cache instead.
    original_main = renpy.main.main

    def main():
        renpy.config.logdir = os.path.join(CACHE, "logs")
        os.makedirs(renpy.config.logdir, exist_ok=True)
        return original_main()

    renpy.main.main = main

    if PATCH_GAME and os.path.isdir(PATCH_GAME) and _has_files(PATCH_GAME):
        _layer_patches()


def _has_files(directory):
    for _root, _dirs, files in os.walk(directory):
        if any(not name.startswith(".") for name in files):
            return True
    return False


def _layer_patches():
    # main() sets config.searchpath = [gamedir] and then asks the launcher script for the
    # common directory; that call is the hook for putting patch/game/ first.
    launcher = renpy.__main__
    original_path_to_common = launcher.path_to_common

    def path_to_common(renpy_base):
        searchpath = renpy.config.searchpath
        if PATCH_GAME not in searchpath:
            searchpath.insert(0, PATCH_GAME)
        return original_path_to_common(renpy_base)

    launcher.path_to_common = path_to_common

    # main() lists archives directory by directory; on PC they all share game/, sorted and
    # reversed so later names take priority. Restore that order across both folders.
    loader = renpy.loader
    original_index_archives = loader.index_archives
    ordered = [False]

    def index_archives():
        if not ordered[0]:
            ordered[0] = True
            names = sorted(set(renpy.config.archives), reverse=True)
            renpy.config.archives[:] = names
            print("Shiori: patch layer active, archives:", names)
        return original_index_archives()

    loader.index_archives = index_archives


def _pointer_cursor():
    """With a trackpad or mouse on an iPad, shows the game's own cursor (config.mouse) the
    way a PC does. iPadOS can't take a picture as its pointer and SDL's iOS backend has no
    cursor support, so the cursor becomes Ren'Py's software cursor (MouseDisplayable), which
    also hides the iPad pointer. It goes away again when a finger takes over. A game that
    already draws its own software cursor is left alone."""
    import ctypes
    try:
        pointer_active = ctypes.CDLL(None).shiori_renpy_pointer_active
    except Exception:
        return
    state = {"on": False, "ours": False}

    def build():
        mouse = renpy.config.mouse
        cursor_class = getattr(renpy.store, "MouseDisplayable", None)
        if not mouse or cursor_class is None:
            return None
        default = mouse.get("default") or list(mouse.values())[0]
        if not default:
            return None
        cursor = cursor_class(*default[0])
        for name, frames in mouse.items():
            if name != "default" and frames:
                cursor.add(name, *frames[0])
        return cursor

    def update():
        on = bool(pointer_active())
        if on == state["on"]:
            return
        state["on"] = on
        if renpy.config.mouse_displayable is not None and not state["ours"]:
            return
        cursor = build() if on else None
        if on and cursor is None:
            return
        renpy.config.mouse_displayable = cursor
        state["ours"] = cursor is not None
        renpy.exports.restart_interaction()

    renpy.config.periodic_callbacks.append(update)


def _gestures():
    """Shiori's shared gestures (RenPyRuntime.m: two-finger swipes and the two-finger hold),
    carried out through the game's own keymap so its settings apply: skip and auto toggle as
    Tab and the auto-forward binding do, the backlog is the game's history screen (rollback
    where it has none), and leaving asks the game to quit its own way (config.quit_action,
    with its own question), which closes the app as quitting always has."""
    import ctypes
    try:
        take = ctypes.CDLL(None).shiori_renpy_take_gesture
    except Exception:
        return
    state = {"keymap": None}

    def history():
        for name in ("history", "text_history", "history_screen"):
            if renpy.exports.has_screen(name):
                return renpy.store.ShowMenu(name)()
        renpy.exports.queue_event("rollback")

    def ensure_keymap():
        keymap = state["keymap"]
        if keymap is None:
            keymap = renpy.display.behavior.Keymap(shiori_history=history)
            state["keymap"] = keymap
        underlay = renpy.config.underlay
        if not any(item is keymap for item in underlay):
            underlay.append(keymap)
            renpy.exports.restart_interaction()

    names = {1: "toggle_skip", 2: "toggle_afm", 3: "shiori_history", 4: "quit"}

    def poll():
        # The game's init has set config.underlay by the time callbacks run.
        ensure_keymap()
        name = names.get(take())
        if name is None:
            return
        print("Shiori: gesture %s" % name)
        renpy.exports.queue_event(name)

    renpy.config.periodic_callbacks.append(poll)


def _background_autosave():
    """Leaving the screen (the home gesture, another app): Ren'Py writes its mobile reload
    save (_reload-1, which isn't in the game's slots) and persistent. Shiori also asks for a
    regular autosave first, as the PC build makes one when it quits (config.autosave_on_quit),
    so the place is in the game's own Auto slots and goes up to iCloud and Steam Cloud with
    the other saves while the app has background time. Skipped when the place hasn't moved
    since the last one, so a quick look at another app doesn't push older autosaves out."""
    interface = getattr(renpy.display.core, "Interface", None)
    original = getattr(interface, "mobile_save", None)
    if original is None:
        return
    state = {"place": None}

    def mobile_save(self):
        try:
            config = renpy.config
            if getattr(config, "autosave_on_quit", True) and getattr(config, "has_autosave", True):
                try:
                    place = renpy.game.context().current
                except Exception:
                    place = None
                if place is not None and place == state["place"]:
                    print("Shiori: background autosave skipped (same place as the last one)")
                else:
                    started = _time.time()
                    try:
                        renpy.loadsave.force_autosave(block=True)
                    except TypeError:
                        renpy.loadsave.force_autosave()
                    state["place"] = place
                    print("Shiori: background autosave asked for (%.2fs)" % (_time.time() - started))
        except Exception:
            print("Shiori: background autosave failed")
            _traceback.print_exc()
        original(self)
        print("Shiori: mobile save written")
        sys.stdout.flush()

    interface.mobile_save = mobile_save


_original_import_all = renpy.import_all


def _import_all():
    _original_import_all()
    _patch_renpy()
    _pointer_cursor()
    _gestures()
    _background_autosave()


renpy.import_all = _import_all

script = os.path.join(GAME_BASE, LAUNCHER)
sys.argv[0] = script
try:
    runpy.run_path(script, run_name="__main__")
except SystemExit as e:
    # The game quit. Return normally instead, so Shiori gets control back and syncs saves
    # (CPython would otherwise call exit() itself, skipping everything after the game).
    _record_exit("SystemExit(%r)" % (e.code,))
    print("Shiori: game exited with %r" % (e.code,))
    sys.stdout.flush()
except BaseException:
    _record_exit("exception")
    # Ren'Py reports its own errors on screen; this catches anything that escapes it,
    # for Shiori to show after the next launch.
    import traceback
    with open(os.path.join(CACHE, "last_error.txt"), "w") as f:
        traceback.print_exc(file=f)
    raise
