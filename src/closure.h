#pragma once
#include "lstate.h"
#include "lapi.h"
#include <unordered_map>

extern std::unordered_map<Closure *, lua_CFunction> cclosure_map;

int call_handler(lua_State *L);
void pushcclosure(lua_State *L, lua_CFunction fn, const char *debugname, int nups);
