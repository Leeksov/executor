// This file is part of the Luau programming language and is licensed under MIT License; see LICENSE.txt for details
// This code is based on Lua 5.x implementation licensed under MIT License; see lua_LICENSE.txt for details
#pragma once

#include "lobject.h"
#include "ltm.h"

// registry
#define registry(L) (&L->global->registry)

// extra stack space to handle TM calls and some other extras
#define EXTRA_STACK 5

#define BASIC_CI_SIZE 8

#define BASIC_STACK_SIZE (2 * LUA_MINSTACK)

// clang-format off
typedef struct stringtable
{
    TString** hash;
    uint32_t nuse; // number of elements
    int size;
} stringtable;
// clang-format on

/*
** informations about a call
**
** the general Lua stack frame structure is as follows:
** - each function gets a stack frame, with function "registers" being stack slots on the frame
** - function arguments are associated with registers 0+
** - function locals and temporaries follow after; usually locals are a consecutive block per scope, and temporaries are allocated after this, but
*this is up to the compiler
**
** when function doesn't have varargs, the stack layout is as follows:
** ^ (func) ^^ [fixed args] [locals + temporaries]
** where ^ is the 'func' pointer in CallInfo struct, and ^^ is the 'base' pointer (which is what registers are relative to)
**
** when function *does* have varargs, the stack layout is more complex - the runtime has to copy the fixed arguments so that the 0+ addressing still
*works as follows:
** ^ (func) [fixed args] [varargs] ^^ [fixed args] [locals + temporaries]
**
** computing the sizes of these individual blocks works as follows:
** - the number of fixed args is always matching the `numparams` in a function's Proto object; runtime adds `nil` during the call execution as
*necessary
** - the number of variadic args can be computed by evaluating (ci->base - ci->func - 1 - numparams)
**
** the CallInfo structures are allocated as an array, with each subsequent call being *appended* to this array (so if f calls g, CallInfo for g
*immediately follows CallInfo for f)
** the `nresults` field in CallInfo is set by the caller to tell the function how many arguments the caller is expecting on the stack after the
*function returns
** the `flags` field in CallInfo contains internal execution flags that are important for pcall/etc, see LUA_CALLINFO_*
*/
// clang-format off
// PATCHED to Roblox ABI (sizeof 0x30). Verified via correctstack(sub_43C7538), stack_init(sub_43D1700),
// luaD_resume(sub_43C8024), and the INTERPRETER dispatch (sub_43D99D8: base=[ci+0x18], savedpc=[ci+0x20]):
// top@0x00, func@0x10, base@0x18, savedpc@0x20, flags@0x2C.
typedef struct CallInfo
{
    StkId top;                  // 0x00 top for this function
    int nresults;               // 0x08 expected number of results
    int _rbxpad0C;              // 0x0C
    StkId func;                 // 0x10 function index in the stack
    StkId base;                 // 0x18 base for this function
    const Instruction* savedpc; // 0x20  (read by the interpreter as the pc)
    int _rbxpad28;              // 0x28
    unsigned int flags;         // 0x2C call frame flags, see LUA_CALLINFO_*
} CallInfo;
// clang-format on

#define LUA_CALLINFO_RETURN (1 << 0) // should the interpreter return after returning from this callinfo? first frame must have this set
#define LUA_CALLINFO_HANDLE (1 << 1) // should the error thrown during execution get handled by continuation from this callinfo? func must be C
#define LUA_CALLINFO_NATIVE (1 << 2) // should this function be executed using execution callback for native code

#define curr_func(L) (clvalue(L->ci->func))
#define ci_func(ci) (clvalue((ci)->func))
#define f_isLua(ci) (!ci_func(ci)->isC)
#define isLua(ci) (ttisfunction((ci)->func) && f_isLua(ci))

struct GCStats
{
    // data for proportional-integral controller of heap trigger value
    int32_t triggerterms[32] = {0};
    uint32_t triggertermpos = 0;
    int32_t triggerintegral = 0;

    size_t atomicstarttotalsizebytes = 0;
    size_t endtotalsizebytes = 0;
    size_t heapgoalsizebytes = 0;

    double starttimestamp = 0;
    double atomicstarttimestamp = 0;
    double endtimestamp = 0;
};

#ifdef LUAI_GCMETRICS
struct GCCycleMetrics
{
    size_t starttotalsizebytes = 0;
    size_t heaptriggersizebytes = 0;

    double pausetime = 0.0; // time from end of the last cycle to the start of a new one

    double starttimestamp = 0.0;
    double endtimestamp = 0.0;

    double marktime = 0.0;
    double markassisttime = 0.0;
    double markmaxexplicittime = 0.0;
    size_t markexplicitsteps = 0;
    size_t markwork = 0;

    double atomicstarttimestamp = 0.0;
    size_t atomicstarttotalsizebytes = 0;
    double atomictime = 0.0;

    // specific atomic stage parts
    double atomictimeupval = 0.0;
    double atomictimeweak = 0.0;
    double atomictimegray = 0.0;
    double atomictimeclear = 0.0;

    double sweeptime = 0.0;
    double sweepassisttime = 0.0;
    double sweepmaxexplicittime = 0.0;
    size_t sweepexplicitsteps = 0;
    size_t sweepwork = 0;

    size_t assistwork = 0;
    size_t explicitwork = 0;

    size_t propagatework = 0;
    size_t propagateagainwork = 0;

    size_t endtotalsizebytes = 0;
};

struct GCMetrics
{
    double stepexplicittimeacc = 0.0;
    double stepassisttimeacc = 0.0;

    // when cycle is completed, last cycle values are updated
    uint64_t completedcycles = 0;

    GCCycleMetrics lastcycle;
    GCCycleMetrics currcycle;
};
#endif

// Callbacks that can be used to to redirect code execution from Luau bytecode VM to a custom implementation (AoT/JiT/sandboxing/...)
struct lua_ExecutionCallbacks
{
    void* context;
    void (*close)(lua_State* L);                 // called when global VM state is closed
    void (*destroy)(lua_State* L, Proto* proto); // called when function is destroyed
    int (*enter)(lua_State* L, Proto* proto);    // called when function is about to start/resume (when execdata is present), return 0 to exit VM
    void (*disable)(lua_State* L, Proto* proto); // called when function has to be switched from native to bytecode in the debugger
    size_t (*getmemorysize)(lua_State* L, Proto* proto); // called to request the size of memory associated with native part of the Proto
    uint8_t (*gettypemapping)(lua_State* L, const char* str, size_t len); // called to get the userdata type index
};

/*
** `global state', shared by all threads of this state
*/
// clang-format off
typedef struct global_State
{
    stringtable strt; // hash table for strings

    lua_Alloc frealloc;   // function to reallocate memory
    void* ud;             // auxiliary data to `frealloc'

    uint8_t currentwhite;
    uint8_t gcstate; // state of garbage collector

    GCObject* gray;      // list of gray objects
    GCObject* grayagain; // list of objects to be traversed atomically
    GCObject* weak;      // list of weak tables (to be cleared)

    size_t GCthreshold;                       // when totalbytes > GCthreshold, run GC step
    size_t totalbytes;                        // number of bytes currently allocated

    int gcgoal;                               // see LUAI_GCGOAL
    int gcstepmul;                            // see LUAI_GCSTEPMUL
    int gcstepsize;                           // see LUAI_GCSTEPSIZE

    struct lua_Page* freepages[LUA_SIZECLASSES]; // free page linked list for each size class for non-collectable objects
    struct lua_Page* freegcopages[LUA_SIZECLASSES]; // free page linked list for each size class for collectable objects
    struct lua_Page* allpages; // page linked list with all pages for all non-collectable object classes (available with LUAU_ASSERTENABLED)
    struct lua_Page* allgcopages; // page linked list with all pages for all collectable object classes
    struct lua_Page* sweepgcopage; // position of the sweep in `allgcopages'

    size_t memcatbytes[LUA_MEMORY_CATEGORIES]; // total amount of memory used by each memory category

    struct lua_State* mainthread;
    UpVal uvhead; // head of double-linked list of all open upvalues
    struct LuaTable* mt[LUA_T_COUNT]; // metatables for basic types
    TString* ttname[LUA_T_COUNT]; // names for basic types
    TString* tmname[TM_N]; // array with tag-method names

    TValue pseudotemp; // storage for temporary values used in pseudo2addr

    TValue registry; // registry table, used by lua_ref and LUA_REGISTRYINDEX
    int registryfree; // next free slot in registry

    struct lua_jmpbuf* errorjmp; // jump buffer data for longjmp-style error handling

    uint64_t rngstate; // PCG random number generator state
    uint64_t ptrenckey[4]; // pointer encoding key for display

    lua_Callbacks cb;

    lua_ExecutionCallbacks ecb;

    void (*udatagc[LUA_UTAG_LIMIT])(lua_State*, void*); // for each userdata tag, a gc callback to be called immediately before freeing memory
    LuaTable* udatamt[LUA_UTAG_LIMIT]; // metatables for tagged userdata

    TString* lightuserdataname[LUA_LUTAG_LIMIT]; // names for tagged lightuserdata

    GCStats gcstats;

#ifdef LUAI_GCMETRICS
    GCMetrics gcmetrics;
#endif
} global_State;
// clang-format on

/*
** `per thread' state
*/
// clang-format off
// PATCHED to Roblox ABI (RobloxLib current build). sizeof == 0x80, verified by emulating
// luaE_newthread (sub_43D1488). Field ORDER is reshuffled vs stock Luau; offsets in comments.
// Cross-verified via reallocstack(sub_43C7538)/reallocCI(sub_43C7700)/stack_init(sub_43D1700)/lua_resume.
struct lua_State
{
    CommonHeader;               // 0x00 tt, 0x01 memcat, 0x02 marked
    uint8_t status;             // 0x03
    uint8_t activememcat;       // 0x04
    bool singlestep;            // 0x05
    bool isactive;              // 0x06
    uint8_t _rbxpad07;          // 0x07

    unsigned short nCcalls;     // 0x08 number of nested C calls
    unsigned short baseCcalls;  // 0x0A nested C calls when resuming coroutine
    int cachedslot;             // 0x0C expected slot for INDEX/NEWINDEX from Luau

    int stacksize;              // 0x10
    int size_ci;                // 0x14 size of array base_ci

    GCObject* gclist;           // 0x18
    UpVal* openupval;           // 0x20 list of open upvalues in this stack
    TString* namecall;          // 0x28 method to invoke for NAMECALL

    global_State* global;       // 0x30
    StkId base;                 // 0x38 base of current function
    StkId stack;                // 0x40 stack base
    StkId stack_last;           // 0x48 last free slot in the stack
    CallInfo* ci;               // 0x50 call info for current function
    StkId top;                  // 0x58 first free slot in the stack
    CallInfo* end_ci;           // 0x60 points after end of ci array
    CallInfo* base_ci;          // 0x68 array of CallInfo's
    LuaTable* gt;               // 0x70 table of globals
    void* userdata;             // 0x78 Roblox extraspace (176B); capabilities @ +0x40
};                              // sizeof == 0x80
// clang-format on

/*
** Union of all collectible objects
*/
union GCObject
{
    GCheader gch;
    struct TString ts;
    struct Udata u;
    struct Closure cl;
    struct LuaTable h;
    struct Proto p;
    struct UpVal uv;
    struct lua_State th; // thread
    struct LuauBuffer buf;
};

// macros to convert a GCObject into a specific value
#define gco2ts(o) check_exp((o)->gch.tt == LUA_TSTRING, &((o)->ts))
#define gco2u(o) check_exp((o)->gch.tt == LUA_TUSERDATA, &((o)->u))
#define gco2cl(o) check_exp((o)->gch.tt == LUA_TFUNCTION, &((o)->cl))
#define gco2h(o) check_exp((o)->gch.tt == LUA_TTABLE, &((o)->h))
#define gco2p(o) check_exp((o)->gch.tt == LUA_TPROTO, &((o)->p))
#define gco2uv(o) check_exp((o)->gch.tt == LUA_TUPVAL, &((o)->uv))
#define gco2th(o) check_exp((o)->gch.tt == LUA_TTHREAD, &((o)->th))
#define gco2buf(o) check_exp((o)->gch.tt == LUA_TBUFFER, &((o)->buf))

// macro to convert any Lua object into a GCObject
#define obj2gco(v) check_exp(iscollectable(v), cast_to(GCObject*, (v) + 0))

LUAI_FUNC lua_State* luaE_newthread(lua_State* L);
LUAI_FUNC void luaE_freethread(lua_State* L, lua_State* L1, struct lua_Page* page);
