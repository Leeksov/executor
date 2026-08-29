# New RobloxLib offsets (imagebase 0x0, offset == address)

## FOUND
- luau_load (rbx)          = 0x43E2CE8   (ref, not needed as ptr; confirms decode)
- opcode decode table T1   = 0x53D1480   (byte, 256, FULL bijection encoded->real)  << opcode_table_addr
- opcode length table      = 0x53D1580   (byte, real->len-code, via sub_3859A1C)
- getOpLength helper        = 0x3859A1C

## Encoder semantics (NEW)
encoded_byte = inverse(T1)[real_opcode]. Old `*227` trick FAILS on this table.
Rewrite BytecodeEncoder to build inverse of opcode_table_addr once.

## STILL NEED (Roblox addrs)
- lua_gettop      (hook target, arg0=lua_State)   old 0x35FCE6C
- rbx_getstate    (ScriptContext getstate)         old 0x57785C
- lua_newthread   (rbx_newthread)                  old 0x35FCDA0
- lua_tolstring   (rlua_tolstring, maybe unused)   old 0x35FD83C

## userdata offsets used by tweak (verify vs new)
- state->userdata + 0x30 = identity
- state->userdata + 0x40 = script_context
- state->userdata + 0x48 = capabilities

## CRITICAL FINDING — Roblox lua_State is NON-STOCK (structs shuffled)
Evidence (raw disasm sub_43BC20C, a thread-push op = definitely lua_State L=X19):
  LDR X8,[X19,#0x30]          -> L->global  @ +0x30   (stock=0x18)
  LDP X8,X9,[X8,#0x50]        -> global->{GCthreshold@+0x50, totalbytes@+0x58}
  LDRB W8,[X19,#2]; TBZ #2    -> L->marked & 4 (threadbarrier)  marked@2 (CommonHeader ok)
  LDP X9,X8,[X19,#0x50]       -> L->top @ +0x58 (stock=0x08)
  setthvalue tag=9 @ [top+0xC]; top += 0x10
Roblox exports ZERO lua_*/luau_* symbols (checked lief: 0). So tweak's plain lua_*
calls bind to its OWN vendored VM. Vendored lstate.h is STOCK (global@0x18, top@0x08).
=> MISMATCH. Roblox shuffled Luau struct field order (anti-executor). Updating the
tweak requires re-aligning vendored Luau struct offsets to Roblox's current ABI, not
just 5 addresses.

Roblox lua_State offsets so far:
  marked @ 0x02
  global @ 0x30
  ??     @ 0x50 (paired w/ top; likely stack_last/ci)
  top    @ 0x58
Roblox global_State offsets:
  GCthreshold @ +0x50
  totalbytes  @ +0x58

## OPCODE ENCODER — SOLVED & EMULATION-VERIFIED
Roblox luau_load decode loop (@0x43e34dc in sub_43E2CE8):
  stored   = T1[onwire]     ; T1 = byte_53D1480 (bijection)  -> internal opcode (dispatch)
  lenarg   = T2[stored]     ; T2 = byte_53D1580 (bijection)  -> standard opcode
  length   = getOpLength(lenarg)   ; sub_3859A1C == standard Luau::getOpLength (emulated, exact 0..82)
=> Roblox renumbered opcodes internally (stored != standard). Single-table inv(T1)
   FAILS length-preservation for 23 opcodes (proven by emulation) -> corrupts loader.
CORRECT ENCODER (standard opcode S -> onwire byte E):
  invT1[x]=T1^-1 ; invT2[x]=T2^-1 ; E = invT1[ invT2[S] ]
Verified by emulating the real decode loop over a 17-word program: all opcodes
(incl len2 GETGLOBAL/GETIMPORT/SETLIST/NAMECALL/LOADKX) decode to invT2[S] and the
length-walk consumes the buffer EXACTLY.
NET IDENTITY (all 256): invT1[invT2[S]] == (227*S)&0xFF  (this is the origin of the
old tweak's *227). Old opcode_table = invT1, old invT2 was linear *227. Now invT2 is
a table; keep runtime composition for robustness.
IMPLEMENT in BytecodeEncoder: build enc[256]=invT1[invT2[.]] from T1@0x53D1480,
T2@0x53D1580 at init; encode: low byte = enc[LUAU_INSN_OP(insn)].

## Roblox lua_State layout (derived) — SCALARS MOVED TO FRONT vs stock
From sub_43C7D94 (lua_resume status-check) + sub_43BC20C (push) + thread ops:
  tt          @ 0x00
  marked      @ 0x02   (barrier checks (marked&4))
  status      @ 0x03
  isactive    @ 0x06   (set =1 on resume)
  nCcalls     @ 0x08   (u16)   [stock had top here]
  baseCcalls  @ 0x0A   (u16)
  ???         @ 0x18   (threadbarrier arg L+0x18 -> gclist?)
  global      @ 0x30   (global_State*)
  ci          @ 0x50   (CallInfo*)   [resume: ci != base_ci check vs +0x68]
  top         @ 0x58   (StkId)
  base_ci     @ 0x68   (CallInfo*)
  (need: base, stack, stack_last, end_ci, gt, userdata, namecall, openupval)
global_State: GCthreshold @ 0x50, totalbytes @ 0x58

## More (from lua_resume sub_43C8024, luaD_resume):
  sizeof(CallInfo) = 0x30 ; CallInfo.flags @ 0x2C
  global_State: cb callbacks near +0x528, +0x558 ; GCthreshold@0x50 totalbytes@0x58
  TValue.tt @ 0x0C (stock), sizeof 16
STILL NEEDED for lua_State: base, stack, stack_last, end_ci, gt, openupval, gclist, namecall, userdata
STILL NEEDED structs: Closure(CClosure/LClosure), Proto, LuaTable, TString, UpVal, extraspace(identity/caps/scriptcontext)

## lua_State POINTER fields (from api_checkstack sub_43B886C) — VERIFY via emu
  global      @ 0x30
  stack       @ 0x38   (a1[7]; used_slots=(top-stack)>>4)
  base        @ 0x40   (guess, between stack and stack_last)
  stack_last  @ 0x48   (a1[9])
  ci          @ 0x50   (a1[10]; *ci = ci->top)
  top         @ 0x58   (a1[11])
  ???         @ 0x60
  base_ci     @ 0x68
CallInfo: sizeof 0x30, top@0x00, flags@0x2C
Still need: base(confirm), end_ci, gt, openupval, gclist, namecall, userdata, size_ci, stacksize, cachedslot

## VERIFICATION STATUS (emulation)
[EMU-OK] lua_State scalars: status@3 marked@2 isactive@6 nCcalls@8 baseCcalls@0xA (via lua_resume sub_43C7D94)
[EMU-OK] lua_State ptrs: stack@0x38 stack_last@0x48 ci@0x50 top@0x58 (via api_checkstack sub_43B886C)
[DERIVED] global@0x30 base_ci@0x68 (via decompile); base@0x40? ?@0x60
[TODO] lua_State: base gt userdata namecall openupval gclist end_ci size_ci stacksize cachedslot
[TODO] structs: Closure Proto LuaTable TString UpVal ; thread extraspace (identity/caps/scriptcontext)
[TODO] funcs: rbx_getstate, rbx_newthread ; then patch vendored headers ; then UNC

## Proto (from internal luau_load sub_43E2CE8)
  k         @ 0x78   (constants array; sizek stored alongside)
  code      @ 0x80   (Instruction*)
  sizek     @ 0x98
  sizecode  @ 0x9C
  TODO: p (child protos), sizep, userdata (capabilities field for set_capabilities)

## Proto (from luau_load pseudocode) — DERIVED
  (bytes) 0x03,0x04,0x05,0x06,0x07 = numparams/maxstacksize/is_vararg/flags/nups (order TBD)
  source     @ 0x20   (TString*)
  p          @ 0x40   (Proto** child protos; alloc 8*sizep, fill p[i])   <-- set_capabilities
  k          @ 0x78   (TValue* constants)
  code       @ 0x80   (Instruction*)
  sizecode   @ 0x90? (dword @0x90=v288 set at newproto) ; sizek @ 0x98 ; sizecode @ 0x9C
  sizep      @ 0x94   <-- set_capabilities
  bytecodeid @ 0xBC
  userdata (capabilities) @ ??? — NOT set in luau_load (caps go to Closure.env@0x10). NEED runtime cap-check to find.

## Closure (luaF_newLclosure sub_43C87DC) — DERIVED
  tag  @ 0x00 (=8 written; note LUA_TFUNCTION handling)
  nups @ 0x04
  env  @ 0x10   (caps/env pointer; luau_load stores script capabilities here)
  p    @ 0x18   (Proto*)   <-- tweak clvalue(...)->l.p
  upvals @ 0x20 (TValue[], 16B stride)
  luaF_newLclosure(L, nups, env, proto); alloc size = 16*nups + 32

## Closure full (luaF_newLclosure 0x43C87DC, luaF_newCclosure 0x43C88F0)
  tag@0x00 (=8), isC@0x03 (1 for C), nups@0x04, stacksize/preload word@0x05
  env @ 0x10
  union @ 0x18:
    LClosure: p@0x18 (Proto*), uprefs@0x20 (TValue[16B])       ; alloc 16*nups+0x20
    CClosure: f@0x18 (CFunction), cont@0x20, debugname@0x28,
              [field@0x30], upvals@0x38 (TValue[16B])           ; alloc 16*nups+0x38
## Proto: sizeof=0xD8 (216), tag@0=15 (LUA_TPROTO). userdata(caps) offset in 0xC0..0xD0 — TBD via runtime cap-check.

## TString (luaS_newlstr 0x43D2010) — DERIVED
  tag@0x00 (=6), atom@0x04, next@0x08 (hashchain), hash@0x10, len@0x14, data@0x18
  header=24B, alloc=len+25, getstr(ts)=ts+0x18
## global_State head (string table strt): hash@0x00, size@0x08, nuse@0x0C  (global @ lua_State+0x30)
## Tags observed (Roblox GCObject tt): TSTRING=6, TFUNCTION/closure=8, TPROTO=15, TTHREAD(TValue)=9

## lua_State.gt @ 0x70  (luau_load default env = &L->gt at a1+112; env is globals table)
