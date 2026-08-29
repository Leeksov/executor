#define IMGUI_DEFINE_MATH_OPERATORS

#include <Foundation/Foundation.h>
#include <MetalKit/MetalKit.h>
#include <Metal/Metal.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

#include "main.h"
#include "exploit.h"
#include "3rdparty/imgui/imgui.h"
#include "3rdparty/imgui/impl/metal.h"

#define kWidth  [UIScreen mainScreen].bounds.size.width
#define kHeight [UIScreen mainScreen].bounds.size.height

@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;
@end

@implementation ImGuiDrawView

static bool showMenu = false;
static char scriptBuf[8192] = "";

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

    io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/CoreUI/SFUIRounded.ttf", 45.0f, NULL, ranges.Data);
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
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
            hasActiveTouch = YES;
            break;
        } else {
            hasActiveTouch = NO;
            break;
        }
    }
    io.MouseDown[0] = hasActiveTouch;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event   { [self updateIOWithTouchEvent:event]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event   { [self updateIOWithTouchEvent:event]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self updateIOWithTouchEvent:event]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event   { [self updateIOWithTouchEvent:event]; }

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
    if (renderPassDescriptor != nil) {
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        ImGui_ImplMetal_NewFrame(renderPassDescriptor);
        ImGui::NewFrame();

        ImFont *font = ImGui::GetFont();
        font->Scale = 14.0f / font->FontSize;

        ImGui::SetNextWindowPos(ImVec2((kWidth / 2) - 200, (kHeight / 2) - 150), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(400, 300), ImGuiCond_FirstUseEver);

        if (showMenu) {
            ImGui::Begin("Executor", &showMenu);
            ImGui::Text("exploit_state = 0x%lX", (uintptr_t)exploit_state);

            ImGui::InputTextMultiline("##script", scriptBuf, sizeof(scriptBuf),
                                      ImVec2(-1, ImGui::GetContentRegionAvail().y - 35));

            if (ImGui::Button("Execute", ImVec2(-1, 30)) && exploit_state) {
                execute_script(scriptBuf);
            }

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

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

void __attribute__((constructor)) initialize() {
    _dyld_register_func_for_add_image([](const struct mach_header *header, intptr_t vmaddr_slide) -> void {
        Dl_info info;
        dladdr(header, &info);
        const char *image = info.dli_fname;

        if (image && strstr(image, "RobloxLib") != NULL) {
            sleep(5);
            NSLog(@"executor | %s loaded at 0x%lX", image, vmaddr_slide);

            dispatch_async(dispatch_get_main_queue(), ^{
                exploit_setup_hooks(vmaddr_slide);
            });
        }
    });
}

@end
