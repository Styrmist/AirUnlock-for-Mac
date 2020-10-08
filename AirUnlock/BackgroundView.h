#define ARROW_WIDTH 12
#define ARROW_HEIGHT 8

#import <AppKit/AppKit.h>

@interface BackgroundView : NSView
{
    NSInteger _arrowX;
}

@property (nonatomic, assign) NSInteger arrowX;

@end
