# Reverse-Engineering Notes

How the Roblox iOS client's Luau VM was reverse-engineered for this executor.
All offsets refer to the current RobloxLib binary (arm64, ~65 MB).

---

## 1. The problem

Roblox embeds a modified Luau VM but:

- Exports **zero** `lua_*` symbols — everything is internal.
- **Reshuffles struct layouts** (`lua_State`, `Proto`, `Closure`, `LuaTable`, `CallInfo`, etc.)
  per build. The standard Luau field order does not match.
- **Encrypts opcodes** — bytecode on-wire uses a permuted opcode set; the interpreter
  dispatches on internal opcode numbers derived through two 256-byte lookup tables.
- Uses a **custom paged allocator** (not the stock `frealloc`-based one) and a paged GC
  that doesn't walk a per-object list the same way stock Luau does.
- Adds **176 bytes of per-thread extraspace** with a capabilities bitmask, identity level,
  and an "AuroraScript" flag checked by `task.defer`.

A vendored Luau that compiles against stock headers will produce bytecode the interpreter
can't dispatch and allocate objects the GC can't track — instant crash.

## 2. Anchoring: finding the entry points

### luau_load (the capture hook)

String-search for `"bytecode version mismatch"` — it appears in exactly one function, which is
Roblox's internal `luau_load`. That function's first argument is a live `lua_State*`.

- **Address:** `sub_43E2CE8`

### The interpreter

String-search for `"%s:%d: "` (the error-format prefix used by `luaG_runerror`). Trace callers
back to a massive function with a jump-table dispatch — that's the interpreter entry.

- **Address:** `sub_43D99D8`
- **Dispatch jump table:** `0x63F0240`, indexed by `opcode * 8`

### Opcode tables

The encoder/decoder tables are two 256-byte arrays used inside the interpreter's opcode-fetch
sequence:

- **T1 (wire → internal):** `0x53D1480`
- **T2 (internal → standard):** `0x53D1580`

Net transform: `standard_op → internal = T1[(227 * standard_op) & 0xFF]`, which equals `invT2[standard_op]`.
Verified for all 83 Luau opcodes by walking the dispatch table.

### Allocators

Found via xrefs to the paged-pool globals. Roblox uses two allocators:

- **GCObject alloc:** `sub_43CF674(L, size, memcat)` → GCObject*
- **Raw alloc:** `sub_43CF4EC(L, size, memcat)` → void*

Neither matches the stock `frealloc(ud, ptr, osize, nsize)` signature. The vendored VM's
`luaM_new_` / `luaM_newgco_` are redirected to call these at runtime.

### Userthread callback

`sub_17A9E2C(parent, L1)` — allocates and initializes the 176-byte extraspace block for a
new thread. Found by tracing what `lua_newthread` calls through `g->cb.userthread` and
matching the allocation size. Called via a redirect (the `g->cb` struct offset doesn't match
stock Luau).

## 3. Deriving the struct ABI

### Method

For each struct, we:

1. **Identified anchor fields** from decompiled code — e.g., the interpreter does
   `ldr x, [L, #offset]` for `L->base`, `L->ci`, `L->top`, etc.
2. **Cross-referenced multiple functions** — `luau_load`, `lua_newthread`, the interpreter,
   `luaD_call`, `luaV_execute`, `task.defer`, GC sweep — to triangulate each field.
3. **Built unicorn (CPU emulation) harnesses** that:
   - Load the actual RobloxLib `.text`/`.rodata`/`.data` sections.
   - Stub external calls (allocators return valid heap, `strlen`/`memcpy` emulated).
   - Execute real Roblox functions on synthetic `lua_State`/`Proto` structs.
   - Assert that the function reads/writes the expected fields at the expected offsets.

### Key results

| Struct | Size | Notable reorderings vs. stock Luau |
|---|---|---|
| `lua_State` | 0x80 | `global@0x30` `base@0x38` `stack@0x40` `ci@0x50` `top@0x58` `base_ci@0x68` `gt@0x70` `userdata@0x78` |
| `Proto` | 0xD8 | `nups@0x03` `maxstacksize@0x07` `source@0x20` `p@0x40` `codeentry@0x68` `k@0x78` `code@0x80` `sizep@0x94` `sizecode@0x9C` `linedefined@0xAC` |
| `CallInfo` | 0x30 | `func@0x10` `base@0x18` `savedpc@0x20` `flags@0x2C` |
| `Closure` | — | `isC@0x03` `env@0x10` `c.f@0x20` `c.cont@0x28` `c.upvals@0x38` |
| `LuaTable` | — | `readonly@0x04` `node@0x10` `array@0x18` `metatable@0x20` |
| `TString` | — | `len@0x14` `data@0x18` |
| `CommonHeader` | 3 bytes | `tt`, `memcat`, `marked` (memcat and marked **swapped** vs. stock) |

Full field-by-field map: [`ABI_SPEC.md`](ABI_SPEC.md).

### Compile-time guards

Every derived offset has a corresponding `static_assert` in `src/main.mm` using `offsetof`.
If Roblox reshuffles the ABI in a future build, the tweak fails to compile instead of
crashing at runtime with silent memory corruption.

## 4. Opcode verification

We dumped all 83 entries from the dispatch jump table at `0x63F0240` and, for each standard
Luau opcode `S`:

1. Computed `internal = invT2[S]`.
2. Looked up `handler = jump_table[internal]`.
3. Disassembled the first few instructions of the handler.
4. Verified the handler matches the expected semantics (e.g., LOP_MOVE copies a register,
   LOP_LOADK loads a constant, LOP_CALL sets up a call frame).

All 83 matched. The encoder in the tweak emits `enc[S] = invT2[S]` so the vendored
compiler's standard opcodes map to the correct Roblox interpreter handlers.

## 5. Bootstrap sequence

1. **Hook** `luau_load` (`sub_43E2CE8`) via substrate/MSHookFunction.
2. On first call, **capture** the game's `lua_State*` from arg0.
3. `lua_newthread(captured_L)` → spawns `exploit_state`. The redirected `rbx_userthread`
   callback allocates Roblox's 176-byte extraspace.
4. **Set capabilities:** write `max_capabilities` to `extraspace + 0x40` and clear the
   AuroraScript flag at `extraspace + 0xA1` (otherwise `task.defer` throws).
5. Register globals (`_G`, `shared`, all UNC functions) on `exploit_state`.
6. Execution: `Luau::compile(source, encoder)` → `luau_load(exploit_state, bytecode)` →
   push closure → `task.defer(closure)`.

## 6. Allocator / GC reconciliation

The vendored Luau VM's allocator (`luaM_new_`, `luaM_newgco_`) is patched to call Roblox's
own allocators at runtime. This ensures every `Proto`, `Closure`, `Table`, and `TString`
created by the vendored `luau_load` lives in Roblox's paged memory pools and is visible to
Roblox's GC.

The vendored GC (`luaC_step`, all barrier functions, `luaC_fullgc`) is gated off when the
redirect is active — Roblox's GC manages the objects; running a second collector on the
same heap would corrupt it.

Free operations (`luaM_free_`, `luaM_freegco_`) are no-ops under redirect — Roblox's paged
allocator doesn't support per-object free; the GC reclaims pages.

## 7. What's NOT reversed (and why)

**Instance reflection** (`gethiddenproperty`, `firesignal`, `getconnections`) routes through
Roblox's descriptor/property system. Each property getter calls through a vtable that
includes telemetry hooks (`*(descriptor+8)(L)`), and using those paths has resulted in
account bans. These entry points are documented in `ABI_SPEC.md` but deliberately not
wired up in the UNC API.

## 8. Tooling

- **IDA Pro** — static analysis of RobloxLib (arm64).
- **lief** — confirmed zero exported `lua_*` symbols.
- **unicorn / rbx.py** — CPU emulation harnesses that load real binary sections and execute
  Roblox functions on synthetic structs to verify offsets.
- **capstone** — disassembly of dispatch-table handlers for opcode verification.
