#import "gestures.h"
#import "../main.h"

@interface Gestures ()
@property (nonatomic, strong) ImGuiDrawView *overlayView;
@end

@implementation Gestures

static Gestures *instance;

+ (void)load {
    [super load];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        instance = [Gestures new];
        [instance initTapGes];
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
    if (!_overlayView) {
        _overlayView = [[ImGuiDrawView alloc] init];
    }
    [ImGuiDrawView showChange:true];
    [[UIApplication sharedApplication].windows[0].rootViewController.view addSubview:_overlayView.view];
}

@end
