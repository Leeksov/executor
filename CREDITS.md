# Credits

## Base project

This executor is **based on the work of [@ra1nbolt](https://github.com/ra1nbolt)**.

The core architecture — capturing a live Roblox Luau state via a function hook, spawning an exploit
thread on it, and executing bytecode through a vendored Luau on the iOS client — originates from his
project. We built on that foundation.

## Our additions

- Re-reverse-engineered the **Luau struct ABI** for the current RobloxLib build (Roblox reshuffles the
  layouts per version). Every offset was derived and **verified via CPU emulation** and is guarded by
  compile-time `static_assert`s. See [`docs/ABI_SPEC.md`](docs/ABI_SPEC.md) and
  [`docs/REVERSING.md`](docs/REVERSING.md).
- Corrected the **opcode encoder** to Roblox's internal opcode numbering (`invT2[S]`), verified against
  Roblox's interpreter dispatch table for all 83 opcodes.
- **Allocator / GC reconciliation**: routed the vendored VM's allocations through Roblox's own paged
  allocator and gated off the vendored collector/barriers so objects are GC-compatible.
- Reworked the **bootstrap** (capture hook, extraspace/capability setup, AuroraScript-flag handling).
- A custom **UNC API** built on safe (telemetry-free) primitives.

## Third-party

- [Luau](https://github.com/luau-lang/luau) — MIT (vendored, patched for ABI alignment).
- [Dear ImGui](https://github.com/ocornut/imgui) — MIT.
- [cpp-httplib](https://github.com/yhirose/cpp-httplib) — MIT.
- [theos](https://github.com/theos/theos) — build system.
