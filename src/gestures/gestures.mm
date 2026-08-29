#import "gestures.h"
#import "../main.h"

@interface Gestures()
@property (nonatomic, strong) ImGuiDrawView *vna;
@end

@implementation Gestures

static Gestures *extraInfo;

+ (void)load {
    [super load];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        extraInfo = [Gestures new];
        [extraInfo initTapGes];
    });
}

- (void)initTapGes {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] init];
    tap.numberOfTapsRequired = 2;
    tap.numberOfTouchesRequired = 3;
    [[UIApplication sharedApplication].keyWindow.rootViewController.view addGestureRecognizer:tap];
    [tap addTarget:self action:@selector(showMenu)];
}

- (void)showMenu {
    if(!_vna) {
        ImGuiDrawView *vc = [[ImGuiDrawView alloc] init];
        _vna = vc;
    }
 
   [ImGuiDrawView showChange:true];
   [[UIApplication sharedApplication].windows[0].rootViewController.view addSubview:_vna.view];
}

@end
