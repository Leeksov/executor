# Executor for Roblox (iOS)

A Luau script executor for the iOS Roblox client, packaged as a `roothide`/Substrate tweak.

It captures a live Roblox Luau state, spawns an isolated exploit thread on it, compiles source with a
vendored Luau compiler, and runs it through **Roblox's own interpreter** (via `task.defer`) with full
capabilities. A small ImGui UI (triple-tap, three fingers) exposes the console.

> **Credits / basis.** This project is **based on the work of [@ra1nbolt](https://github.com/ra1nbolt)**.
> The overall approach (hook-based state capture + vendored-Luau execution on the iOS client) comes from
> his project; this repo adds our own reverse-engineering for the current RobloxLib build, a re-derived
> and emulation-verified Luau ABI, an allocator/GC reconciliation layer, and a custom (UNC) API.
> See [`CREDITS.md`](CREDITS.md).

---

## What's here

- **`src/main.mm`** — tweak entry, capture hook, bootstrap, bytecode encoder, execution, ImGui UI.
- **`src/unc.h`** — the custom Luau API (UNC surface).
- **`src/closure.h`** — C-closure trampoline (`pushcclosure` / `call_handler`).
- **`src/3rdparty/luau/`** — vendored Luau (compiler + VM), **patched to Roblox's current ABI** (see docs).
- **`docs/`** — the reverse-engineering writeup and the full offset spec.

## How it works (short version)

1. **Capture.** Hook Roblox's internal `luau_load`; its first arg is a live game `lua_State`.
2. **Bootstrap.** `lua_newthread` off the captured state; the (redirected) userthread callback allocates
   Roblox's 176-byte per-thread *extraspace*; set the capability mask to grant everything.
3. **Compile.** `Luau::compile` + a custom `BytecodeEncoder` that emits Roblox's *internal* opcode numbers.
4. **Load.** The vendored `luau_load` builds a `Proto`/`Closure` — allocated through **Roblox's own paged
   allocator** so the objects are tracked by Roblox's GC.
5. **Run.** `task.defer(closure)`; Roblox's scheduler resumes it through Roblox's interpreter, whose
   dispatch table was verified to map our encoded opcodes to the correct handlers for all 83 opcodes.

Full technical detail: [`docs/REVERSING.md`](docs/REVERSING.md).

## The hard part: the Luau ABI

Roblox reshuffles the Luau struct layouts (`lua_State`, `Proto`, `Closure`, `LuaTable`, `CallInfo`, …)
per build as an anti-executor measure, and exports **zero** `lua_*` symbols, so the vendored VM's own
`lua_*` functions must be aligned to Roblox's layout or they corrupt state. Every offset in this repo was
**re-derived and verified via CPU emulation** (unicorn) against the actual binary, and is guarded by
`static_assert` in `main.mm` — so a future reshuffle fails the build instead of crashing silently on device.
Full map: [`docs/ABI_SPEC.md`](docs/ABI_SPEC.md).

## Custom API (UNC)

Implemented on **safe primitives** (iOS-native + Luau C-API + verified struct fields), deliberately avoiding
telemetry-heavy engine calls:

| Group | Functions |
|---|---|
| Filesystem | `readfile` `writefile` `appendfile` `isfile` `isfolder` `makefolder` `delfile` `delfolder` `listfiles` `loadfile` |
| Crypt | `crypt.base64encode/decode` `crypt.generatebytes` `crypt.generatekey` `crypt.hash` |
| Metatable | `getrawmetatable` `setrawmetatable` `setreadonly` `isreadonly` `getnamecallmethod` |
| Closures | `iscclosure` `islclosure` `isexecutorclosure` `checkcaller` `newcclosure` `clonefunction` `hookfunction` |
| Debug | `debug.getinfo/getconstants/getconstant/getprotos/getupvalues` |
| Env / misc | `getgenv` `getrenv` `getreg` `loadstring` `request` `setclipboard` `identifyexecutor` `compareinstances` `get/setthreadidentity` |

Instance/reflection functions (`gethiddenproperty`, `firesignal`, `fireproximityprompt`, `getconnections`)
are intentionally **not** implemented on the reflection path — they route through telemetry-heavy engine
getters. Entry points are documented in `docs/ABI_SPEC.md` if you want them behind a flag.

## Build

Requires [theos](https://theos.dev) with the `roothide` scheme and an arm64 toolchain.

```sh
make package        # produces a .deb in packages/
make package install # build + install to a connected device
```

The `static_assert`s in `src/main.mm` validate every derived struct offset at compile time — if the build
fails there, Roblox changed the ABI and the offsets in `docs/ABI_SPEC.md` need re-deriving.

## Disclaimer

For educational and security-research purposes. Modifying the Roblox client violates Roblox's Terms of
Service and can result in account bans. Use on accounts and devices you own and accept the risk for. The
authors take no responsibility for how this is used.

## License

MIT — see [`LICENSE`](LICENSE).
