# VN Hub's entry point for Ren'Py games. Ren'Py's iOS launcher runs this as main.py from a
# runner folder (Library/Caches/RenPy/<game>/runner/base/, whose lib/ links to the game's
# lib/), so it can set things up before handing over to the game's own launcher script.
#
# It keeps the game's base/ folder byte-identical to what Steam delivered, so verify stays
# meaningful: Python bytecode and Ren'Py's cache/ files are written under VNHUB_CACHE.

import os
import sys
import runpy

GAME_BASE = os.environ["VNHUB_GAME_BASE"]
LAUNCHER = os.environ["VNHUB_LAUNCHER"]
CACHE = os.environ["VNHUB_CACHE"]

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

    # bootstrap sets config.logdir to the game's base folder just before main();
    # log.txt and traceback.txt go to the cache instead.
    original_main = renpy.main.main

    def main():
        renpy.config.logdir = os.path.join(CACHE, "logs")
        os.makedirs(renpy.config.logdir, exist_ok=True)
        return original_main()

    renpy.main.main = main


_original_import_all = renpy.import_all


def _import_all():
    _original_import_all()
    _patch_renpy()


renpy.import_all = _import_all

script = os.path.join(GAME_BASE, LAUNCHER)
sys.argv[0] = script
try:
    runpy.run_path(script, run_name="__main__")
except SystemExit:
    raise
except BaseException:
    # Ren'Py reports its own errors on screen; this catches anything that escapes it,
    # for VN Hub to show after the next launch.
    import traceback
    with open(os.path.join(CACHE, "last_error.txt"), "w") as f:
        traceback.print_exc(file=f)
    raise
