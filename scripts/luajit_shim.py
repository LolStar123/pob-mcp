"""A `luajit script.lua [args...]` command line hosted on Path of Building's own lua51.dll.

Why: current PoB source uses compound assignment (`x += 1`), which stock LuaJIT cannot
parse, and PoB ships its patched LuaJIT only as runtime/lua51.dll with no CLI. This
loads that DLL through ctypes and runs a script the way luajit.exe would: global `arg`
table, script arguments as `...`, stdio inherited (the DLL's C runtime owns it, so
JSON-lines over stdin/stdout works unchanged).

Setup (Windows, 64-bit Python 3.8+, no compiler or extra packages needed):
    POB_CMD = C:/path/to/pob-mcp/scripts/luajit_shim.py
    POB_PATH = C:/path/to/PathOfBuilding/src           (a checkout; see README)

The DLL is found from POB_RUNTIME, else <cwd>/../runtime (a checkout's src/), else <cwd>,
else POB_PATH/../runtime, else POB_PATH.
    python luajit_shim.py -v      prints the DLL it would use
"""
import ctypes
import os
import sys


def find_runtime():
    pob_path = os.environ.get("POB_PATH") or os.environ.get("POB_FORK_PATH")
    candidates = [os.environ.get("POB_RUNTIME"),
                  os.path.join(os.getcwd(), "..", "runtime"),
                  os.getcwd(),
                  pob_path and os.path.join(pob_path, "..", "runtime"),
                  pob_path]
    for c in candidates:
        if c and os.path.isfile(os.path.join(c, "lua51.dll" if os.name == "nt" else "libluajit.so")):
            return os.path.abspath(c)
    sys.stderr.write("luajit_shim: no lua51.dll found (set POB_RUNTIME to PoB's runtime folder)\n")
    sys.exit(2)


def main():
    argv = sys.argv[1:]
    runtime = find_runtime()
    if argv[:1] == ["-v"]:
        print(f"luajit_shim using {os.path.join(runtime, 'lua51.dll')}")
        return 0
    if not argv:
        sys.stderr.write("usage: luajit_shim.py script.lua [args...]\n")
        return 2

    if hasattr(os, "add_dll_directory"):
        os.add_dll_directory(runtime)  # zlib1.dll, lua-utf8.dll, lcurl.dll ... live here too
    os.environ["PATH"] = runtime + os.pathsep + os.environ.get("PATH", "")
    lua = ctypes.CDLL(os.path.join(runtime, "lua51.dll"))
    vp, cp, i = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int
    lua.luaL_newstate.restype = vp
    lua.luaL_openlibs.argtypes = [vp]
    lua.luaL_loadfile.argtypes = [vp, cp]
    lua.lua_pcall.argtypes = [vp, i, i, i]
    lua.lua_tolstring.argtypes = [vp, i, vp]
    lua.lua_tolstring.restype = cp
    lua.lua_createtable.argtypes = [vp, i, i]
    lua.lua_pushstring.argtypes = [vp, cp]
    lua.lua_rawseti.argtypes = [vp, i, i]
    lua.lua_setfield.argtypes = [vp, i, cp]
    LUA_GLOBALSINDEX = -10002

    L = lua.luaL_newstate()
    lua.luaL_openlibs(L)
    lua.lua_createtable(L, len(argv), 1)               # arg = { [-1]=interp, [0]=script, ... }
    lua.lua_pushstring(L, sys.executable.encode()); lua.lua_rawseti(L, -2, -1)
    for n, a in enumerate(argv):
        lua.lua_pushstring(L, a.encode("utf-8")); lua.lua_rawseti(L, -2, n)
    lua.lua_setfield(L, LUA_GLOBALSINDEX, b"arg")

    def fail(stage):
        msg = lua.lua_tolstring(L, -1, None)
        sys.stderr.write(f"luajit_shim: {stage}: {msg.decode('utf-8', 'replace') if msg else '?'}\n")
        sys.stderr.flush()
        os._exit(1)

    # `-` reads the script from stdin, as luajit does (luaL_loadfile(NULL)).
    if lua.luaL_loadfile(L, None if argv[0] == "-" else argv[0].encode("utf-8")) != 0:
        fail("load")
    for a in argv[1:]:
        lua.lua_pushstring(L, a.encode("utf-8"))
    if lua.lua_pcall(L, len(argv) - 1, 0, 0) != 0:
        fail("run")
    sys.stdout.flush()
    os._exit(0)  # skip interpreter teardown racing the Lua state


if __name__ == "__main__":
    sys.exit(main())
