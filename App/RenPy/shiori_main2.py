# -*- coding: utf-8 -*-
# Shiori's entry point for games that run on Ren'Py bundled with Shiori rather than their
# own engine code: 6.10-7.x games on 7.8.7 (Python 2), and 8.0 games on 8.1.3 (Python 3).
# Ren'Py's iOS launcher runs this as main.py from a runner folder
# (Library/Caches/RenPy/<game>/runner/base/) whose lib/, renpy/ and renpy.py are that
# bundled Ren'Py (RenPy7Base or RenPy8Base). The game's own
# game/ folder is used as is; its bundled renpy/ is not, since older 7.x engine code can't
# run on 7.8.7's compiled modules (Ren'Py 7.8 runs games made with older 7.x and 6.99).
#
# Like shiori_main.py for Ren'Py 8, it keeps the game's base/ folder byte-identical to what
# Steam delivered (caches and logs go to SHIORI_CACHE) and layers patch/game over game/.
from __future__ import print_function

import os
import sys

GAME_BASE = os.environ["SHIORI_GAME_BASE"]
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

# The runner's lib/ and renpy/ are inside the app bundle; never try to write .pyo there.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
RENPY_PY = os.path.join(HERE, "renpy.py")
# The bundled renpy/ sits next to this file (Python 2's launcher already looks here).
if HERE not in sys.path:
    sys.path.insert(0, HERE)


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
                print("Shiori: stand-in for", name)
                return SteamStub(name)
            return real_cdll.__new__(cls)

    ctypes.CDLL = CDLL


_stub_steam_api()

import renpy  # noqa: E402  (the bundled Ren'Py, from the runner's renpy/)


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

    # Image cache use every 5 seconds: size against its limit, and how many images were
    # loaded since (a cache that keeps reloading would show here; the user's iPhone ran out of
    # memory in Sakura Swim Club with no characters drawn).
    import time
    cache_report = [time.time(), 0]
    recent_loads = []
    image_cache = renpy.display.im.Cache
    original_add_load_log = image_cache.add_load_log

    def add_load_log(self, filename):
        cache_report[1] += 1
        recent_loads.append(filename)
        del recent_loads[:-3]
        return original_add_load_log(self, filename)

    image_cache.add_load_log = add_load_log

    def report_cache():
        now = time.time()
        if now - cache_report[0] < 5:
            return
        cache_report[0] = now
        try:
            cache = renpy.display.im.cache
            loads = cache_report[1]
            cache_report[1] = 0
            recent = ", ".join(str(name)[:60] for name in recent_loads) if loads else ""
            textures = ""
            try:
                size, count = renpy.display.draw.get_texture_size()
                textures = ", GL textures %d" % count
                freed = getattr(renpy.config, "shiori_freed_textures", None)
                if freed is not None:
                    textures += ", %d freed by Shiori" % freed[0]
            except Exception:
                pass
            # Ren'Py 7 counts the cache in pixels (cache_size, cache_limit); 8 doesn't keep them.
            size = getattr(cache, "cache_size", None)
            limit = getattr(cache, "cache_limit", None)
            usage = ", %d MB of %d MB" % (size * 4 // 1048576, limit * 4 // 1048576) if size is not None and limit is not None else ""
            _say_cache("entries %d%s, %d loads%s%s" % (
                len(cache.cache), usage, loads, textures, (" (latest: " + recent + ")") if recent else ""))
        except Exception as e:
            _say_cache("unavailable (%r)" % (e,))

    def _say_cache(text):
        print("Shiori image cache: " + text)
        sys.stdout.flush()

    renpy.config.periodic_callbacks.append(report_cache)
    controller.init = init
    controller.start = start
    controller.post_event = post_event

    # GL textures are freed by GLTexture.__del__, which this runtime's Cython compiled into a
    # Python 3 finalizer (tp_finalize) that Python 2 never calls: every texture Ren'Py drew to
    # and dropped stayed allocated. Each game menu (screenshots, transitions) kept 40-70 of
    # them, and the user's iPhone ran out of memory after a dozen menus (Sakura Swim Club, DDLC,
    # Fatal Twelve; Ren'Py 8 on Python 3 was fine). Give the Python subclass a real __del__
    # that queues the texture, and delete queued textures between frames, as Ren'Py's own
    # TextureLoader.cleanup() would.
    try:
        if sys.version_info[0] != 2:
            raise ImportError("Python 3 runs the finalizer itself")
        import ctypes
        import renpy.gl2.gl2texture as gl2texture

        runtime = ctypes.CDLL(os.environ["SHIORI_RUNTIME_LIBRARY"])
        get_proc = runtime.SDL_GL_GetProcAddress
        get_proc.restype = ctypes.c_void_p
        get_proc.argtypes = [ctypes.c_char_p]
        delete_textures = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint))
        gl_delete = [None]
        doomed = []
        freed = [0]

        # Each texture remembers its generation: Ren'Py kills every texture before a resize
        # and when the app goes to the background (Interface.kill_textures), then makes new
        # ones whose numbers start over, keeping the same loader. An old texture dying later
        # must not delete a new texture that reuses its number (games drew black after
        # returning from the Home Screen).
        generation = [0]
        interface_class = renpy.display.core.Interface
        original_kill_textures = interface_class.kill_textures

        def kill_textures(self, *args, **kwargs):
            generation[0] += 1
            del doomed[:]
            return original_kill_textures(self, *args, **kwargs)

        def texture_init(self, size, loader, *args, **kwargs):
            gl2texture.GLTexture.__init__(self, size, loader, *args, **kwargs)
            self.__dict__["_shiori_generation"] = generation[0]

        def texture_del(self):
            try:
                if self.loaded and self.number and self.__dict__.get("_shiori_generation") == generation[0]:
                    doomed.append(self.number)
            except Exception:
                pass

        def free_doomed():
            if not doomed:
                return
            live = list(doomed)
            del doomed[:]
            if gl_delete[0] is None:
                address = get_proc(b"glDeleteTextures")
                if not address:
                    return
                gl_delete[0] = delete_textures(address)
            numbers = (ctypes.c_uint * len(live))(*live)
            gl_delete[0](len(live), numbers)
            freed[0] += len(live)

        if not hasattr(gl2texture.GLTexture, "__del__"):
            interface_class.kill_textures = kill_textures
            gl2texture.Texture.__init__ = texture_init
            gl2texture.Texture.__del__ = texture_del
            renpy.config.periodic_callbacks.append(free_doomed)
            renpy.config.shiori_freed_textures = freed
    except Exception as e:
        print("Shiori textures: no fix (%r)" % (e,))

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
            # A binding with no keys: Shiori queues it by name. Unregistered, Ren'Py parses the
            # name as a key ("Invalid key specifier shiori_history") when the game's own
            # screens map events, which crashed Ren'Py 6/7 games at their main menu.
            renpy.config.keymap.setdefault("shiori_history", [])
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
