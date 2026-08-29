#define IMGUI_DEFINE_MATH_OPERATORS

#include <Foundation/Foundation.h>
#include <MetalKit/MetalKit.h>
#include <Metal/Metal.h>
#include <mach-o/dyld.h>

#include "main.h"
#include "3rdparty/imgui/imgui.h"
#include "3rdparty/imgui/impl/metal.h"

#include <substrate.h>
#include "mach-o/dyld.h"
#include "dlfcn.h"

#include "lua.h"
#include "lapi.h"
#include "lstate.h"
#include "lualib.h"
#include "Luau/Compiler.h"
#include "Luau/BytecodeUtils.h"
#include "Luau/BytecodeBuilder.h"

#include "loadscript.h"
#include "closure.h"
#include "unc.h"

#include <cstddef>
// Compile-time verification of the patched vendored lua_State against Roblox's current ABI
// (all offsets emulation-verified via luaE_newthread / reallocstack / reallocCI). If Roblox
// reshuffles again, these fire at build time instead of crashing silently on device.
static_assert(sizeof(lua_State) == 0x80,               "lua_State size != 0x80 (Roblox ABI changed)");
static_assert(offsetof(lua_State, global)   == 0x30,   "lua_State.global offset");
static_assert(offsetof(lua_State, base)     == 0x38,   "lua_State.base offset");
static_assert(offsetof(lua_State, stack)    == 0x40,   "lua_State.stack offset");
static_assert(offsetof(lua_State, ci)       == 0x50,   "lua_State.ci offset");
static_assert(offsetof(lua_State, top)      == 0x58,   "lua_State.top offset");
static_assert(offsetof(lua_State, base_ci)  == 0x68,   "lua_State.base_ci offset");
static_assert(offsetof(lua_State, gt)       == 0x70,   "lua_State.gt offset");
static_assert(offsetof(lua_State, userdata) == 0x78,   "lua_State.userdata offset");
// object structs (verified vs Roblox luau_load writes / constructors run in unicorn)
static_assert(sizeof(Proto) == 0xD8,                   "Proto size != 0xD8");
static_assert(offsetof(Proto, code) == 0x80,           "Proto.code offset");
static_assert(offsetof(Proto, k)    == 0x78,           "Proto.k offset");
static_assert(offsetof(Proto, p)    == 0x40,           "Proto.p offset");
static_assert(offsetof(Proto, sizep)== 0x94,           "Proto.sizep offset");
static_assert(offsetof(Proto, sizecode) == 0x9C,       "Proto.sizecode offset");
static_assert(offsetof(Proto, nups) == 0x03,           "Proto.nups offset (EMU: nups@0x03)");
static_assert(offsetof(Proto, maxstacksize) == 0x07,   "Proto.maxstacksize offset (EMU)");
static_assert(offsetof(Proto, source) == 0x20,         "Proto.source offset");
static_assert(offsetof(Proto, codeentry) == 0x68,      "Proto.codeentry offset");
static_assert(offsetof(Proto, linedefined) == 0xAC,    "Proto.linedefined offset (EMU)");
static_assert(offsetof(Closure, env)== 0x10,           "Closure.env offset");
static_assert(offsetof(LuaTable, node)     == 0x10,    "LuaTable.node offset");
static_assert(offsetof(LuaTable, array)    == 0x18,    "LuaTable.array offset");
static_assert(offsetof(LuaTable, metatable)== 0x20,    "LuaTable.metatable offset");
static_assert(offsetof(TString, len)  == 0x14,         "TString.len offset");
static_assert(offsetof(TString, data) == 0x18,         "TString.data offset");
static_assert(sizeof(CallInfo) == 0x30,                "CallInfo size != 0x30");
static_assert(offsetof(CallInfo, func) == 0x10,        "CallInfo.func offset");
static_assert(offsetof(CallInfo, base) == 0x18,        "CallInfo.base offset");
static_assert(offsetof(CallInfo, savedpc) == 0x20,     "CallInfo.savedpc offset (interpreter pc)");
static_assert(offsetof(CallInfo, flags)== 0x2C,        "CallInfo.flags offset");

#define kWidth [UIScreen mainScreen].bounds.size.width
#define kHeight [UIScreen mainScreen].bounds.size.height

#define trampoline_hook(target, replace, orig) MSHookFunction((void *)(target), (void *)replace, (void **)&orig); NSLog(@"executor | added trampoline hook at 0x%lX to 0x%lX", uintptr_t(target), uintptr_t(replace))
#define init_func(func, addr) func = (decltype(func))(addr)

// Capture hook: Roblox's internal luau_load (sub_43E2CE8). arg0 is the lua_State that is loading a
// script (a real game thread), arg1 is the load-context struct. Fires on every script load, and is
// anchored by the string "bytecode version mismatch" so it survives version bumps.
long long (*rbx_luau_load)(lua_State *L, void *ctx);

// Roblox's userthread callback (sub_17A9E2C): allocates + inherits the 176-byte extraspace and sets
// the new thread's userdata. Called by the patched vendored lua_newthread (see lapi.cpp) because
// Roblox's lua_Callbacks live at a global_State offset the vendored layout doesn't match.
void (*rbx_userthread)(lua_State *parent, lua_State *L1) = nullptr;

@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;
@end

@implementation ImGuiDrawView

// Roblox renumbers Luau opcodes internally. Two 256-byte bijections drive it:
//   T1 (byte_53D1480): on-wire  -> internal (dispatch) opcode
//   T2 (byte_53D1580): internal -> standard opcode (used for getOpLength)
// This tweak uses its OWN vendored luau_load, which stores instruction words VERBATIM into
// Proto->code; Roblox's interpreter then dispatches on those bytes as INTERNAL opcodes (dispatch
// table @ 0x63f0240, verified for all 83 opcodes). So the encoder must emit internal opcodes:
//   enc[standard S] = invT2[S]     (needs only T2)
// This equals the historic trick T1[(227*S)&0xff] (verified T1[227*S] == invT2[S] on this build).
uintptr_t opcode_t1_addr; // byte_53D1480 : on-wire  -> internal opcode  (decode table)
uintptr_t opcode_t2_addr; // byte_53D1580 : internal -> standard opcode (length table)

uintptr_t max_capabilities = 0xFFFFFFFFFFFFFFFF;
void set_capabilities(Proto *proto, uintptr_t *capabilities) {
    // Modern Roblox is capability-based at the THREAD level: the effective mask is read from
    // extraspace+0x40 (verified via sub_174F418), which set_identity() sets to all-ones. Per-proto
    // userdata is not the gating mechanism in this build, so we deliberately do NOT write
    // proto->userdata here — its exact Roblox offset is a gap that could alias gclist, and a bad
    // write would corrupt the GC. If a future build re-gates on proto capabilities, re-enable this
    // once proto->userdata's offset is confirmed on-device.
    (void)proto; (void)capabilities;
}

void set_identity(lua_State *state, uint8_t identity) {
    // NOTE: requires the vendored lua_State layout to be patched to Roblox's ABI so that
    // state->userdata resolves to the extraspace pointer at lua_State+0x78 (verified via
    // lua_get/setthreaddata @ 0x43bbc24/0x43bbc2c).
    uintptr_t userdata = (uintptr_t)state->userdata; // extraspace (176 bytes)

    // Modern Roblox is capability-based; the effective capability mask lives at
    // extraspace+0x40 (verified by emulating sub_174F418, which reads *(userdata+0x40)).
    // Setting it to all-ones grants every capability. The legacy integer "identity"
    // field from older builds (+0x30) no longer gates access.
    *(uint64_t *)(userdata + 0x40) = max_capabilities;

    // Clear the AuroraScript flag at extraspace+0xA1: task.defer (sub_173D61C) throws
    // "task.defer is not available for AuroraScripts" when it is set, and our thread inherits the
    // captured script's flags via the userthread copy-ctor. Clearing it keeps task.defer usable.
    *(uint8_t *)(userdata + 0xA1) = 0;
    (void)identity;
}

lua_State *exploit_state;

int identifyexecutor(lua_State *L) {
    lua_pushstring(L, "leeksov executor v1.0");
    return 1;
}

int testf(lua_State *L) {
    const char *str = luaL_checkstring(L, -1);
    lua_pushstring(L, str);
    return 1;
}

void register_function(lua_State *L, const std::string &name, lua_CFunction function) {
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    pushcclosure(L, function, name.c_str(), 0);
    lua_setfield(L, -2, name.c_str());
    lua_pop(L, 1);
}

void init_exploit(lua_State *roblox_state) {
    if (exploit_state) return;
    NSLog(@"executor | initializing exploit from captured state at 0x%lX", (uintptr_t)roblox_state);

    // Spawn our own thread off the captured Roblox state. The patched vendored lua_newthread invokes
    // Roblox's userthread callback (rbx_userthread) which allocates + inherits the 176-byte extraspace
    // and sets exploit_state->userdata (emulation-verified). We then elevate its capability mask.
    exploit_state = lua_newthread(roblox_state);
    set_identity(exploit_state, 8); // extraspace.capabilities @ +0x40 = all

    // NOTE: we intentionally do NOT call luaL_sandboxthread here — it reads g->mt[] at a global_State
    // offset that differs from Roblox's, which would corrupt state. lua_newthread already shares the
    // captured thread's global table (L1->gt = L->gt), so game/task/etc. are directly reachable.
    lua_newtable(exploit_state);
    lua_setglobal(exploit_state, "_G");

    lua_newtable(exploit_state);
    lua_setglobal(exploit_state, "shared");

    register_function(exploit_state, "identifyexecutor", identifyexecutor);
    register_function(exploit_state, "test", testf);
    register_unc(exploit_state);

    lua_settop(exploit_state, 0);
}

class BytecodeEncoder : public Luau::BytecodeEncoder {
    uint8_t enc[256]; // standard Luau opcode -> Roblox INTERNAL opcode (dispatch value)

public:
    BytecodeEncoder() {
        // The exploit path is: our (vendored) luau_load stores instruction words VERBATIM into
        // Proto->code, then Roblox's interpreter runs the closure (via task.defer) and dispatches
        // on those bytes as INTERNAL opcodes. So the encoder must emit internal opcodes directly.
        //   T2 (byte_53D1580) maps internal -> standard, so internal = invT2[standard].
        // Equivalent to the historic trick: T1[(S*227)&0xff] == invT2[S] on this build (verified).
        const uint8_t *T2 = (const uint8_t *)opcode_t2_addr; // internal -> standard
        for (int s = 0; s < 256; s++) enc[s] = 0;
        for (int internal = 0; internal < 256; internal++) enc[T2[internal]] = (uint8_t)internal; // enc[standard]=internal
    }

    inline void encode(uint32_t *data, size_t count) override {
        for (size_t i = 0; i < count;) {
            uint8_t opcode = LUAU_INSN_OP(data[i]);
            data[i] = enc[opcode] | (data[i] & ~0xFFu);
            i += Luau::getOpLength(static_cast<LuauOpcode>(opcode));
        }
    }
};

std::string compile_script(const std::string &source) {
    static BytecodeEncoder bytecode_encoder = BytecodeEncoder();
    static const char *common_globals[] = {"Game", "game", "Workspace", "workspace", "plugin", "script", "_G", "shared", "_ENV", nullptr};

    Luau::CompileOptions options;
    options.debugLevel = 1;
    options.optimizationLevel = 1;
    options.mutableGlobals = common_globals;
    options.vectorLib = "Vector3";
    options.vectorCtor = "new";
    options.vectorType = "Vector3";

    return Luau::compile(source, options, {}, &bytecode_encoder);
}

void execute_script(const std::string &script) {
    std::string bytecode = compile_script(script);

    lua_getglobal(exploit_state, "task");
    lua_getfield(exploit_state, -1, "defer");

    if (luau_load(exploit_state, "=executor", bytecode.c_str(), bytecode.size(), 0) != 0) {
        lua_getglobal(exploit_state, "error");
        lua_pushstring(exploit_state, lua_tostring(exploit_state, -1));
        lua_call(exploit_state, 1, 0);

        lua_settop(exploit_state, 0);

        return;
    }

    Closure *closure = clvalue(luaA_toobject(exploit_state, -1));
    set_capabilities(closure->l.p, &max_capabilities);
    set_identity(exploit_state, 8);

    lua_pcall(exploit_state, 1, 0, 0);

    lua_settop(exploit_state, 0);
}

long long rbx_luau_load_hk(lua_State *L, void *ctx) {
    if (!exploit_state) init_exploit(L);
    return rbx_luau_load(L, ctx);
}

static bool showMenu = false;
ImFont* font;

- (instancetype)initWithNibName:(nullable NSString *)name bundle:(nullable NSBundle *)bundle {
    self = [super initWithNibName:name bundle:bundle];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];

    if (!self.device) abort();

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();

    ImGui::StyleColorsDark();
    
    ImVector<ImWchar> ranges;
    ImFontGlyphRangesBuilder builder;
    builder.AddRanges(io.Fonts->GetGlyphRangesKorean());
    builder.AddRanges(io.Fonts->GetGlyphRangesChineseFull());
    builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
    builder.AddRanges(io.Fonts->GetGlyphRangesJapanese());
    builder.AddRanges(io.Fonts->GetGlyphRangesCyrillic());
    builder.AddRanges(io.Fonts->GetGlyphRangesThai());
    builder.AddRanges(io.Fonts->GetGlyphRangesVietnamese());
    builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
    builder.BuildRanges(&ranges);

    font = io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/CoreUI/SFUIRounded.ttf", 45.0f, NULL, ranges.Data);
    
    ImGui_ImplMetal_Init(self.device);

    return self;
}

+ (void)showChange:(BOOL)open {
    showMenu = open;
}

- (MTKView *)mtkView {
    return (MTKView *)self.view;
}

- (void)loadView {
    self.view = [[MTKView alloc] initWithFrame:CGRectMake(0, 0, kWidth, kHeight)];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.mtkView.device = self.device;
    self.mtkView.delegate = self;
    self.mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.mtkView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0];
    self.mtkView.clipsToBounds = YES;
}

#pragma mark - Interaction

- (void)updateIOWithTouchEvent:(UIEvent *)event {
    UITouch *anyTouch = event.allTouches.anyObject;
    CGPoint touchLocation = [anyTouch locationInView:self.view];
    ImGuiIO &io = ImGui::GetIO();
    io.MousePos = ImVec2(touchLocation.x, touchLocation.y);

    BOOL hasActiveTouch = NO;
    for(UITouch *touch in event.allTouches) {
        if(touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
            hasActiveTouch = YES;
            break;
        } else {
            hasActiveTouch = NO;
            break;
        }
    }
    io.MouseDown[0] = hasActiveTouch;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateIOWithTouchEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateIOWithTouchEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateIOWithTouchEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateIOWithTouchEvent:event];
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView *)view {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = {(float)view.bounds.size.width, (float)view.bounds.size.height};

    [self.view setUserInteractionEnabled:showMenu];

    CGFloat framebuffer_scale = view.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    io.DisplayFramebufferScale = {(float)framebuffer_scale, (float)framebuffer_scale};
    io.DeltaTime = 1 / float(view.preferredFramesPerSecond ?: 60);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if(renderPassDescriptor != nil) {
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        
        ImGui_ImplMetal_NewFrame(renderPassDescriptor);
        ImGui::NewFrame();

        ImFont* font = ImGui::GetFont();
        font->Scale = 14.0f / font->FontSize;
        
        ImGui::SetNextWindowPos(ImVec2((kWidth / 2) - 200, (kHeight / 2) - 150), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(400, 300), ImGuiCond_FirstUseEver);

        if(showMenu == true) {
            ImGui::Begin("Executor", &showMenu);

            ImGui::Text("exploit_state = 0x%lX", (uintptr_t)exploit_state);

            if (ImGui::Button("exec: print(\"Hello from Luau!\")")) {
                execute_script(script);
            }

            if (ImGui::Button("kill lp")) {
                execute_script("game.Players.LocalPlayer.Character.Humanoid.Health -= math.huge");
            }

            if (ImGui::Button("unc")) {
                execute_script(unc);
            }

            if (ImGui::Button("httptesthttptest")) {
                execute_script(httptest);
            }

            if (ImGui::Button("dex console")) {
                execute_script(printall);
            }

            if (ImGui::Button("id exec")) {
                execute_script("print(identifyexecutor())");
            }

            uint8_t *t = (uint8_t *)opcode_t1_addr;
            ImGui::Text("Opcode table first bytes:\n"
                        "\t0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x\n"
                        "\t0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x\n"
                        "\t0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x\n"
                        "\t0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x\n",
                        t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7],
                        t[8], t[9], t[10], t[11], t[12], t[13], t[14], t[15],
                        t[16], t[17], t[18], t[19], t[20], t[21], t[22], t[23],
                        t[24], t[25], t[26], t[27], t[28], t[29], t[30], t[31]);

            ImGui::End();
        }

        ImGui::Render();
        ImDrawData *draw_data = ImGui::GetDrawData();
        ImGui_ImplMetal_RenderDrawData(draw_data, commandBuffer, renderEncoder);
        
        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
    }
    [commandBuffer commit];
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

void __attribute__((constructor)) initialize() {
    _dyld_register_func_for_add_image([] (const struct mach_header *header, intptr_t vmaddr_slide) -> void {
        Dl_info info;
        dladdr(header, &info);
        const char *image = info.dli_fname;
        
        if (image && strstr(image, "RobloxLib") != NULL) {
            sleep(5);
            NSLog(@"executor | %s loaded at 0x%lX", image, vmaddr_slide);

            dispatch_async(dispatch_get_main_queue(), ^{
                // Opcode encryption tables (verified for current RobloxLib build).
                opcode_t1_addr = vmaddr_slide + 0x53D1480; // byte_53D1480 : on-wire  -> internal
                opcode_t2_addr = vmaddr_slide + 0x53D1580; // byte_53D1580 : internal -> standard

                // Route the vendored VM's allocations through Roblox's OWN paged allocator so every
                // object lands in Roblox's pages and is managed by Roblox's GC (the vendored paged
                // allocator would read Roblox's global_State at the wrong page-list offsets).
                //   sub_43CF674 = luaM_newgco (GC objects), sub_43CF4EC = raw arrays. Both (L,size,memcat).
                extern GCObject *(*rbx_gco_alloc)(lua_State *, size_t, uint8_t);
                extern void *(*rbx_raw_alloc)(lua_State *, size_t, uint8_t);
                rbx_gco_alloc = (GCObject *(*)(lua_State *, size_t, uint8_t))(vmaddr_slide + 0x43CF674);
                rbx_raw_alloc = (void *(*)(lua_State *, size_t, uint8_t))(vmaddr_slide + 0x43CF4EC);

                // Roblox userthread callback (extraspace setup) for the patched vendored lua_newthread.
                rbx_userthread = (void (*)(lua_State *, lua_State *))(vmaddr_slide + 0x17A9E2C);

                // Capture hook: Roblox's internal luau_load (sub_43E2CE8). Fires on every script
                // load with a real game lua_State as arg0; we spawn our exploit thread off it.
                // Anchored by the "bytecode version mismatch" string so it is stable across builds.
                trampoline_hook(vmaddr_slide + 0x43E2CE8, rbx_luau_load_hk, rbx_luau_load);
            });
        }
    });
}

@end

