#pragma once
#include <cstdint>

namespace rbx {
    // Roblox function vmaddr offsets (current RobloxLib build, imagebase 0)
    constexpr uintptr_t kLuauLoad    = 0x43E2CE8;
    constexpr uintptr_t kUserthread  = 0x17A9E2C;
    constexpr uintptr_t kGcoAlloc    = 0x43CF674;
    constexpr uintptr_t kRawAlloc    = 0x43CF4EC;

    // Opcode encryption tables
    constexpr uintptr_t kOpcodeT1    = 0x53D1480; // on-wire  → internal
    constexpr uintptr_t kOpcodeT2    = 0x53D1580; // internal → standard

    // Per-thread extraspace layout
    constexpr uintptr_t kCapabilities  = 0x40;
    constexpr uintptr_t kAuroraFlag    = 0xA1;
}
