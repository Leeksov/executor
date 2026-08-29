// This file is part of the Luau programming language and is licensed under MIT License; see LICENSE.txt for details
// This code is based on Lua 5.x implementation licensed under MIT License; see lua_LICENSE.txt for details
#pragma once

#include "lua.h"
#include "lcommon.h"

/*
** Union of all collectible objects
*/
typedef union GCObject GCObject;

/*
** Common Header for all collectible objects (in macro form, to be included in other objects)
*/
// clang-format off
// PATCHED to Roblox ABI: memcat/marked are SWAPPED vs stock Luau.
// Verified in luaE_newthread (sub_43D1488): obj[0]=tt, obj[1]=memcat, obj[2]=marked&3.
#define CommonHeader \
     uint8_t tt; uint8_t memcat; uint8_t marked
// clang-format on

/*
** Common header in struct form
*/
typedef struct GCheader
{
    CommonHeader;
} GCheader;

/*
** Union of all Lua values
*/
typedef union
{
    GCObject* gc;
    void* p;
    double n;
    int b;
    float v[2]; // v[0], v[1] live here; v[2] lives in TValue::extra
} Value;

/*
** Tagged Values
*/

typedef struct lua_TValue
{
    Value value;
    int extra[LUA_EXTRA_SIZE];
    int tt;
} TValue;

// Macros to test type
#define ttisnil(o) (ttype(o) == LUA_TNIL)
#define ttisnumber(o) (ttype(o) == LUA_TNUMBER)
#define ttisstring(o) (ttype(o) == LUA_TSTRING)
#define ttistable(o) (ttype(o) == LUA_TTABLE)
#define ttisfunction(o) (ttype(o) == LUA_TFUNCTION)
#define ttisboolean(o) (ttype(o) == LUA_TBOOLEAN)
#define ttisuserdata(o) (ttype(o) == LUA_TUSERDATA)
#define ttisthread(o) (ttype(o) == LUA_TTHREAD)
#define ttisbuffer(o) (ttype(o) == LUA_TBUFFER)
#define ttislightuserdata(o) (ttype(o) == LUA_TLIGHTUSERDATA)
#define ttisvector(o) (ttype(o) == LUA_TVECTOR)
#define ttisupval(o) (ttype(o) == LUA_TUPVAL)

// Macros to access values
#define ttype(o) ((o)->tt)
#define gcvalue(o) check_exp(iscollectable(o), (o)->value.gc)
#define pvalue(o) check_exp(ttislightuserdata(o), (o)->value.p)
#define nvalue(o) check_exp(ttisnumber(o), (o)->value.n)
#define vvalue(o) check_exp(ttisvector(o), (o)->value.v)
#define tsvalue(o) check_exp(ttisstring(o), &(o)->value.gc->ts)
#define uvalue(o) check_exp(ttisuserdata(o), &(o)->value.gc->u)
#define clvalue(o) check_exp(ttisfunction(o), &(o)->value.gc->cl)
#define hvalue(o) check_exp(ttistable(o), &(o)->value.gc->h)
#define bvalue(o) check_exp(ttisboolean(o), (o)->value.b)
#define thvalue(o) check_exp(ttisthread(o), &(o)->value.gc->th)
#define bufvalue(o) check_exp(ttisbuffer(o), &(o)->value.gc->buf)
#define upvalue(o) check_exp(ttisupval(o), &(o)->value.gc->uv)

#define l_isfalse(o) (ttisnil(o) || (ttisboolean(o) && bvalue(o) == 0))

#define lightuserdatatag(o) check_exp(ttislightuserdata(o), (o)->extra[0])

// Internal tags used by the VM
#define LU_TAG_ITERATOR LUA_UTAG_LIMIT

/*
** for internal debug only
*/
#define checkconsistency(obj) LUAU_ASSERT(!iscollectable(obj) || (ttype(obj) == (obj)->value.gc->gch.tt))

#define checkliveness(g, obj) LUAU_ASSERT(!iscollectable(obj) || ((ttype(obj) == (obj)->value.gc->gch.tt) && !isdead(g, (obj)->value.gc)))

// Macros to set values
#define setnilvalue(obj) ((obj)->tt = LUA_TNIL)

#define setnvalue(obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.n = (x); \
        i_o->tt = LUA_TNUMBER; \
    }

#if LUA_VECTOR_SIZE == 4
#define setvvalue(obj, x, y, z, w) \
    { \
        TValue* i_o = (obj); \
        float* i_v = i_o->value.v; \
        i_v[0] = (x); \
        i_v[1] = (y); \
        i_v[2] = (z); \
        i_v[3] = (w); \
        i_o->tt = LUA_TVECTOR; \
    }
#else
#define setvvalue(obj, x, y, z, w) \
    { \
        TValue* i_o = (obj); \
        float* i_v = i_o->value.v; \
        i_v[0] = (x); \
        i_v[1] = (y); \
        i_v[2] = (z); \
        i_o->tt = LUA_TVECTOR; \
    }
#endif

#define setpvalue(obj, x, tag) \
    { \
        TValue* i_o = (obj); \
        i_o->value.p = (x); \
        i_o->extra[0] = (tag); \
        i_o->tt = LUA_TLIGHTUSERDATA; \
    }

#define setbvalue(obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.b = (x); \
        i_o->tt = LUA_TBOOLEAN; \
    }

#define setsvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TSTRING; \
        checkliveness(L->global, i_o); \
    }

#define setuvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TUSERDATA; \
        checkliveness(L->global, i_o); \
    }

#define setthvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TTHREAD; \
        checkliveness(L->global, i_o); \
    }

#define setbufvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TBUFFER; \
        checkliveness(L->global, i_o); \
    }

#define setclvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TFUNCTION; \
        checkliveness(L->global, i_o); \
    }

#define sethvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TTABLE; \
        checkliveness(L->global, i_o); \
    }

#define setptvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TPROTO; \
        checkliveness(L->global, i_o); \
    }

#define setupvalue(L, obj, x) \
    { \
        TValue* i_o = (obj); \
        i_o->value.gc = cast_to(GCObject*, (x)); \
        i_o->tt = LUA_TUPVAL; \
        checkliveness(L->global, i_o); \
    }

#define setobj(L, obj1, obj2) \
    { \
        const TValue* o2 = (obj2); \
        TValue* o1 = (obj1); \
        *o1 = *o2; \
        checkliveness(L->global, o1); \
    }

/*
** different types of sets, according to destination
*/

// to stack
#define setobj2s setobj
// from table to same table (no barrier)
#define setobjt2t setobj
// to table (needs barrier)
#define setobj2t setobj
// to new object (no barrier)
#define setobj2n setobj

#define setttype(obj, tt) (ttype(obj) = (tt))

#define iscollectable(o) (ttype(o) >= LUA_TSTRING)

typedef TValue* StkId; // index to stack elements

/*
** String headers for string table
*/
typedef struct TString
{
    CommonHeader;
    // 1 byte padding

    int16_t atom;

    // 2 byte padding

    TString* next; // next string in the hash table bucket

    unsigned int hash;
    unsigned int len;

    char data[1]; // string data is allocated right after the header
} TString;


#define getstr(ts) (ts)->data
#define svalue(o) getstr(tsvalue(o))

typedef struct Udata
{
    CommonHeader;

    uint8_t tag;

    int len;

    struct LuaTable* metatable;

    // userdata is allocated right after the header
    // while the alignment is only 8 here, for sizes starting at 16 bytes, 16 byte alignment is provided
    alignas(8) char data[1];
} Udata;

typedef struct LuauBuffer
{
    CommonHeader;

    unsigned int len;

    alignas(8) char data[1];
} Buffer;

/*
** Function Prototypes
*/
// clang-format off
// PATCHED to Roblox ABI (sizeof 0xD8). Field offsets in comments. EXECUTION-CRITICAL fields
// (bytes, code@0x80, k@0x78, p@0x40, codeentry@0x68, source@0x20, typeinfo@0x08, size* dwords,
// bytecodeid@0xBC) are CONFIRMED from Roblox luau_load(sub_43E2CE8) writes. AUX/debug fields
// (lineinfo/abslineinfo/locvars/upvalues/debugname/debuginsn + their sizes) are placed at the
// remaining Roblox write-slots; their exact name<->slot pairing is best-effort (debug-only, does
// not affect execution). Gap slots (execdata/exectarget/userdata/gclist) are set by non-luau_load
// code; keep them out of the execution-critical offsets. TODO: confirm aux/gap pairing on-device.
// PATCHED to Roblox ABI (sizeof 0xD8). ALL field offsets emulation-VERIFIED by running Roblox's
// loadsafe (sub_43E2CE8) on a crafted bytecode blob and reading back the Proto (verify_proto.py).
// Sentinels confirmed: maxstacksize@0x07, nups@0x03 (NOT swapped like stock), debugname@0x18,
// abslineinfo@0x50, sizecode@0x9C, sizelocvars@0x88, linedefined@0xAC, linegaplog2@0xA8, etc.
// Gap fields (execdata/exectarget/debuginsn/userdata/gclist) are not written by luau_load and are
// placed at the unused slots; they don't affect execution.
typedef struct Proto
{
    CommonHeader;               // 0x00
    uint8_t nups;               // 0x03  [EMU]
    uint8_t flags;              // 0x04
    uint8_t numparams;          // 0x05
    uint8_t is_vararg;          // 0x06  [EMU]
    uint8_t maxstacksize;       // 0x07  [EMU]

    uint8_t* typeinfo;          // 0x08
    uint8_t* lineinfo;          // 0x10  [EMU]
    TString* debugname;         // 0x18  [EMU]
    TString* source;            // 0x20  [EMU]
    struct LocVar* locvars;     // 0x28  [EMU]
    void* execdata;             // 0x30  [Roblox codegen; gap]
    uintptr_t exectarget;       // 0x38  [Roblox codegen; gap]
    struct Proto** p;           // 0x40  [EMU]
    TString** upvalues;         // 0x48  [EMU]
    int* abslineinfo;           // 0x50  [EMU]
    uint8_t* debuginsn;         // 0x58  [gap]
    GCObject* gclist;           // 0x60  [gap/GC]
    const Instruction* codeentry; // 0x68 [EMU]
    void* userdata;             // 0x70  [host; gap]
    TValue* k;                  // 0x78  [EMU] constants
    Instruction* code;          // 0x80  [EMU] function bytecode

    int sizelocvars;            // 0x88  [EMU]
    int sizeupvalues;           // 0x8C  [EMU]
    int _rbxpad90;              // 0x90  [Roblox-only]
    int sizep;                  // 0x94  [EMU]
    int sizek;                  // 0x98  [EMU]
    int sizecode;               // 0x9C  [EMU]
    int sizetypeinfo;           // 0xA0
    int sizelineinfo;           // 0xA4  [EMU]
    int linegaplog2;            // 0xA8  [EMU]
    int linedefined;            // 0xAC  [EMU]
    void* _rbxpadB0;            // 0xB0  [Roblox-only ptr]
    int _rbxpadB8;              // 0xB8  [Roblox-only]
    int bytecodeid;             // 0xBC
    void* _rbxpadC0;            // 0xC0
    uintptr_t _rbxpadC8;        // 0xC8
    void* _rbxpadD0;            // 0xD0
} Proto;                        // sizeof == 0xD8
// clang-format on

typedef struct LocVar
{
    TString* varname;
    int startpc; // first point where variable is active
    int endpc;   // first point where variable is dead
    uint8_t reg; // register slot, relative to base, where variable is stored
} LocVar;

/*
** Upvalues
*/

typedef struct UpVal
{
    CommonHeader;
    uint8_t markedopen; // set if reachable from an alive thread (only valid during atomic)

    // 4 byte padding (x64)

    TValue* v; // points to stack or to its own value
    union
    {
        TValue value; // the value (when closed)
        struct
        {
            // global double linked list (when open)
            struct UpVal* prev;
            struct UpVal* next;

            // thread linked list (when open)
            struct UpVal* threadnext;
        } open;
    } u;
} UpVal;

#define upisopen(up) ((up)->v != &(up)->u.value)

/*
** Closures
*/

typedef struct Closure
{
    CommonHeader;

    uint8_t isC;
    uint8_t nupvalues;
    uint8_t stacksize;
    uint8_t preload;

    GCObject* gclist;
    struct LuaTable* env;

    union
    {
        struct
        {
            lua_CFunction f;         // 0x18
            lua_Continuation cont;   // 0x20
            const char* debugname;   // 0x28
            void* _rbxpad30;         // 0x30  Roblox has an extra slot before upvals
            TValue upvals[1];        // 0x38
        } c;

        struct
        {
            struct Proto* p;
            TValue uprefs[1];
        } l;
    };
} Closure;

#define iscfunction(o) (ttype(o) == LUA_TFUNCTION && clvalue(o)->isC)
#define isLfunction(o) (ttype(o) == LUA_TFUNCTION && !clvalue(o)->isC)

/*
** Tables
*/

typedef struct TKey
{
    ::Value value;
    int extra[LUA_EXTRA_SIZE];
    unsigned tt : 4;
    int next : 28; // for chaining
} TKey;

typedef struct LuaNode
{
    TValue val;
    TKey key;
} LuaNode;

// copy a value into a key
#define setnodekey(L, node, obj) \
    { \
        LuaNode* n_ = (node); \
        const TValue* i_o = (obj); \
        n_->key.value = i_o->value; \
        memcpy(n_->key.extra, i_o->extra, sizeof(n_->key.extra)); \
        n_->key.tt = i_o->tt; \
        checkliveness(L->global, i_o); \
    }

// copy a value from a key
#define getnodekey(L, obj, node) \
    { \
        TValue* i_o = (obj); \
        const LuaNode* n_ = (node); \
        i_o->value = n_->key.value; \
        memcpy(i_o->extra, n_->key.extra, sizeof(i_o->extra)); \
        i_o->tt = n_->key.tt; \
        checkliveness(L->global, i_o); \
    }

// clang-format off
// PATCHED to Roblox ABI (sizeof 0x30). node/metatable SWAPPED vs stock (node@0x10, metatable@0x20).
// Verified via luaH_new(sub_43D581C)/luaH_clone(sub_43D6524): node@0x10=&dummynode, array@0x18, metatable@0x20.
typedef struct LuaTable
{
    CommonHeader;       // 0x00
    uint8_t tmcache;    // 0x03  1<<p means tagmethod(p) is not present
    uint8_t readonly;   // 0x04  sandboxing feature to prohibit writes to table
    uint8_t lsizenode;  // 0x05  log2 of size of `node' array (luaH_new sets 0xFF for empty)
    uint8_t safeenv;    // 0x06  environment doesn't share globals with other scripts
    uint8_t nodemask8;  // 0x07  (1<<lsizenode)-1, truncated to 8 bits

    int sizearray; // 0x08  size of `array' array
    union
    {
        int lastfree;  // 0x0C
        int aboundary;
    };

    LuaNode* node;              // 0x10  (empty -> &dummynode)
    TValue* array;              // 0x18  array part
    struct LuaTable* metatable; // 0x20
    GCObject* gclist;           // 0x28
} LuaTable;
// clang-format on

/*
** `module' operation for hashing (size is always a power of 2)
*/
#define lmod(s, size) (check_exp((size & (size - 1)) == 0, (cast_to(int, (s) & ((size)-1)))))

#define twoto(x) ((int)(1 << (x)))
#define sizenode(t) (twoto((t)->lsizenode))

#define luaO_nilobject (&luaO_nilobject_)

LUAI_DATA const TValue luaO_nilobject_;

#define ceillog2(x) (luaO_log2((x)-1) + 1)

LUAI_FUNC int luaO_log2(unsigned int x);
LUAI_FUNC int luaO_rawequalObj(const TValue* t1, const TValue* t2);
LUAI_FUNC int luaO_rawequalKey(const TKey* t1, const TValue* t2);
LUAI_FUNC int luaO_str2d(const char* s, double* result);
LUAI_FUNC const char* luaO_pushvfstring(lua_State* L, const char* fmt, va_list argp);
LUAI_FUNC const char* luaO_pushfstring(lua_State* L, const char* fmt, ...);
LUAI_FUNC const char* luaO_chunkid(char* buf, size_t buflen, const char* source, size_t srclen);
