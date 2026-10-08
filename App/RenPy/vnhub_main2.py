# -*- coding: utf-8 -*-
# VN Hub's entry point for Ren'Py 6.99 / 7.x games (Python 2). Ren'Py's iOS launcher runs
# this as main.py from a runner folder (Library/Caches/RenPy/<game>/runner/base/) whose
# lib/, renpy/ and renpy.py link to Ren'Py 7.8.7 bundled with VN Hub. The game's own
# game/ folder is used as is; its bundled renpy/ is not, since older 7.x engine code can't
# run on 7.8.7's compiled modules (Ren'Py 7.8 runs games made with older 7.x and 6.99).
#
# Like vnhub_main.py for Ren'Py 8, it keeps the game's base/ folder byte-identical to what
# Steam delivered (caches and logs go to VNHUB_CACHE) and layers patch/game over game/.
from __future__ import print_function

import os
import sys

GAME_BASE = os.environ["VNHUB_GAME_BASE"]
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

# The runner's lib/ and renpy/ are inside the app bundle; never try to write .pyo there.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
RENPY_PY = os.path.join(HERE, "renpy.py")


def _makedirs(path):
    if not os.path.isdir(path):
        os.makedirs(path)


def _log_error():
    import traceback
    with open(os.path.join(CACHE, "last_error.txt"), "w") as f:
        traceback.print_exc(file=f)


def _has_files(directory):
    for _root, _dirs, files in os.walk(directory):
        if any(not name.startswith(".") for name in files):
            return True
    return False


def _stub_steam_api():
    """Some games load the PC Steam API themselves with ctypes (steam_api.dll,
    libsteam_api.so/.dylib), which doesn't exist on iOS. Hand them a library that answers
    like a PC without Steam running: SteamAPI_Init() is False, every other call returns 0."""
    import ctypes

    class SteamFunction(object):
        def __init__(self, name):
            self.__name__ = name
            self.restype = None
            self.argtypes = None

        def __call__(self, *args):
            return False if self.restype is ctypes.c_bool else 0

    class SteamStub(object):
        def __init__(self, name):
            self._name = name

        def __getattr__(self, name):
            if name.startswith("__"):
                raise AttributeError(name)
            function = SteamFunction(name)
            setattr(self, name, function)
            return function

        __getitem__ = __getattr__

    real_cdll = ctypes.CDLL

    class CDLL(real_cdll):
        def __new__(cls, name, *args, **kwargs):
            if name and "steam_api" in os.path.basename(str(name)).lower():
                print("VN Hub: stand-in for", name)
                return SteamStub(name)
            return real_cdll.__new__(cls)

    ctypes.CDLL = CDLL


_stub_steam_api()

import renpy  # noqa: E402  (Ren'Py 7.8.7 from the runner's renpy/)


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
        path = _cache_path(fn)
        if path is None:
            return original_get_path(fn)
        _makedirs(os.path.dirname(path))
        return path

    def load(name, directory=None, tl=True):
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

    # Compiled scripts from Ren'Py before 6.99 (Sakura Swim Club's 6.18) predate the
    # Translate statement's `alternate` slot, so loading them failed with
    # "AttributeError: alternate". Give it the default newer compilers write.
    translate = renpy.ast.Translate
    if "__new__" not in translate.__dict__:
        def translate_new(cls, *args, **kwargs):
            self = super(translate, cls).__new__(cls)
            self.alternate = None
            return self
        translate.__new__ = staticmethod(translate_new)

    # Recompiled .rpyc/.rpymc files are written next to their source; send those writes
    # to the cache so base/ stays as Steam delivered it (Ren'Py recompiles each launch).
    script = renpy.script
    original_open = getattr(script, "open", open)
    game_base = os.path.realpath(GAME_BASE) + os.sep

    def script_open(name, mode="r", *args, **kwargs):
        if any(c in mode for c in "wa+"):
            path = os.path.realpath(name)
            if path.startswith(game_base):
                name = os.path.join(CACHE, "writes", path[len(game_base):])
                _makedirs(os.path.dirname(name))
        return original_open(name, mode, *args, **kwargs)

    script.open = script_open

    launcher = renpy.__main__

    def path_to_logdir(basedir):
        logs = os.path.join(CACHE, "logs")
        _makedirs(logs)
        return logs

    launcher.path_to_logdir = path_to_logdir

    if PATCH_GAME and os.path.isdir(PATCH_GAME) and _has_files(PATCH_GAME):
        original_searchpath = launcher.predefined_searchpath

        def predefined_searchpath(commondir):
            searchpath = original_searchpath(commondir)
            if PATCH_GAME not in searchpath:
                searchpath.insert(0, PATCH_GAME)
            return searchpath

        launcher.predefined_searchpath = predefined_searchpath

        original_index_archives = loader.index_archives
        ordered = [False]

        def index_archives():
            # Archives from patch/game and game/ ordered as if they shared one folder (PC).
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

# The launcher hands us [main.py, --savedir, <saves>]; Ren'Py wants the game's base folder
# as its first argument so config.basedir / gamedir point at the game, not the runner.
sys.argv = [RENPY_PY, GAME_BASE] + sys.argv[1:]
try:
    # (The bundled Python 2.7 library has no runpy.)
    with open(RENPY_PY, "rb") as f:
        code = compile(f.read(), RENPY_PY, "exec")
    # Ren'Py finds path_to_gamedir and friends through sys.modules["__main__"].
    import types
    main = types.ModuleType("__main__")
    main.__file__ = RENPY_PY
    main.__builtins__ = __builtins__
    sys.modules["__main__"] = main
    exec(code, main.__dict__)
except SystemExit as e:
    # The game quit. Return normally instead, so Shiori gets control back and syncs saves
    # (CPython would otherwise call exit() itself, skipping everything after the game).
    _record_exit("SystemExit(%r)" % (e.code,))
    print("Shiori: game exited with %r" % (e.code,))
    sys.stdout.flush()
except BaseException:
    _record_exit("exception")
    _log_error()
    raise
