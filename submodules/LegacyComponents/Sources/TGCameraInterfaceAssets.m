#import <LegacyComponents/TGCameraInterfaceAssets.h>
#import <CoreText/CoreText.h>

#import "LegacyComponentsInternal.h"

@implementation TGCameraInterfaceAssets

+ (UIColor *)normalColor
{
    return [UIColor whiteColor];
}

+ (UIColor *)accentColor
{
    return UIColorRGB(0xf8d74a);
}

+ (UIColor *)redColor
{
    return UIColorRGB(0xfe3b30);
}

+ (UIColor *)panelBackgroundColor
{
    return [UIColor blackColor];
}

+ (UIColor *)buttonColor
{
    return UIColorRGBA(0x393737, 0.6);
}

+ (UIColor *)transparentPanelBackgroundColor
{
    return [UIColor colorWithWhite:0.0f alpha:0.5];
}

+ (UIColor *)transparentOverlayBackgroundColor
{
    return [UIColor colorWithWhite:0.0f alpha:0.7];
}

+ (UIFont *)regularFontOfSize:(CGFloat)size
{
    return [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
}

+ (UIFont *)boldFontOfSize:(CGFloat)size
{
    return [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
}

@end
