#include "closure.h"

std::unordered_map<Closure *, lua_CFunction> cclosure_map;

int call_handler(lua_State *L) {
    auto idx = cclosure_map.find(curr_func(L));
    return idx != cclosure_map.end() ? idx->second(L) : 0;
}

void pushcclosure(lua_State *L, lua_CFunction fn, const char *debugname, int nups) {
    lua_pushcclosurek(L, call_handler, debugname, nups, 0);
    cclosure_map[clvalue(luaA_toobject(L, -1))] = fn;
}
