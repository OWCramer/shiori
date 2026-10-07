# VN Hub's entry point for Ren'Py games. Ren'Py's iOS launcher runs this as main.py from a
# runner folder (Library/Caches/RenPy/<game>/runner/base/, whose lib/ links to the game's
# lib/), so it can set things up before handing over to the game's own launcher script.
#
# It keeps the game's base/ folder byte-identical to what Steam delivered, so verify stays
# meaningful: Python bytecode and Ren'Py's cache/ files are written under VNHUB_CACHE.
#
# It also layers the game's patch/game/ folder (VNHUB_PATCH_GAME) over base/game/: loose
# files and scripts there shadow the game's own, and archives (.rpa) in either folder are
# ordered as if they all sat in one game/ folder, as they would on PC.

import os
import sys
import runpy

GAME_BASE = os.environ["VNHUB_GAME_BASE"]
LAUNCHER = os.environ["VNHUB_LAUNCHER"]
CACHE = os.environ["VNHUB_CACHE"]
PATCH_GAME = os.environ.get("VNHUB_PATCH_GAME", "")


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
            print("VN Hub: patch layer active, archives:", names)
        return original_index_archives()

    loader.index_archives = index_archives


_original_import_all = renpy.import_all


def _import_all():
    _original_import_all()
    _patch_renpy()


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
    # for VN Hub to show after the next launch.
    import traceback
    with open(os.path.join(CACHE, "last_error.txt"), "w") as f:
        traceback.print_exc(file=f)
    raise
