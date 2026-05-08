# Vendored LuaSocket

Pre-built [LuaSocket](https://lunarmodules.github.io/luasocket/) artifacts that get loaded into FCEUX's embedded Lua 5.1 by `bridge.lua`. Committed to the repo so users don't need a C toolchain.

## What's here

- `lib/lua/5.1/socket/core.so`, `lib/lua/5.1/mime/core.so` — Lua C modules
- `share/lua/5.1/*.lua`, `share/lua/5.1/socket/*.lua` — pure-Lua modules

The directory layout mirrors a standard `make install` of LuaSocket so `package.cpath` / `package.path` setup is straightforward.

## Versions

| Component | Version | Source |
| --- | --- | --- |
| Lua (headers only, for build) | 5.1.5 | https://www.lua.org/ftp/lua-5.1.5.tar.gz |
| LuaSocket | 3.1.0 | https://github.com/lunarmodules/luasocket/archive/refs/tags/v3.1.0.tar.gz |

## Platforms

| Platform | Status |
| --- | --- |
| `macos-arm64` | Built and verified against FCEUX 2.6.6 (Homebrew) |
| `macos-x86_64` | Not yet built |
| `linux-x86_64` | Not yet built |
| `windows-x86_64` | Not yet built |

## Rebuilding

The exact steps used to produce `macos-arm64/`:

```sh
PREFIX="$(mktemp -d)"
curl -sL https://www.lua.org/ftp/lua-5.1.5.tar.gz | tar xz
( cd lua-5.1.5 && make macosx && make install INSTALL_TOP="$PREFIX" )

curl -sL https://github.com/lunarmodules/luasocket/archive/refs/tags/v3.1.0.tar.gz | tar xz
( cd luasocket-3.1.0 && \
  make PLAT=macosx LUAV=5.1 LUAINC_macosx="$PREFIX/include" LUAPREFIX_macosx="$PREFIX" && \
  make install PLAT=macosx LUAV=5.1 LUAINC_macosx="$PREFIX/include" LUAPREFIX_macosx="$PREFIX" prefix="$PREFIX" )

# Then copy $PREFIX/lib/lua/5.1/{socket,mime}/core.so and $PREFIX/share/lua/5.1/**.lua
# into vendor/luasocket/<platform>/.
```

## Why ABI-compatible

LuaSocket's `.so` is compiled against Lua 5.1.5 headers from the source tarball. On macOS the bundle is linked with `-undefined dynamic_lookup`, so when FCEUX `dlopen`s it the `lua_*` C-API symbols are resolved against FCEUX's own statically-linked Lua at load time — not against any Lua interpreter on the host. As long as both ends are Lua 5.1.x, this works.
