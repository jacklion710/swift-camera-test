//
//  OpenCVWrapper.h
//  swift-camera-test
//
//  Created by Jacob Leone on 6/30/25.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface OpenCVWrapper : NSObject

// Main comparison method
+ (NSDictionary *)compareImages:(UIImage *)image1 with:(UIImage *)image2;

// Individual processing steps (exposed for testing/debugging)
+ (BOOL)isDigitalRender:(UIImage *)image;
+ (UIImage *)preprocessImage:(UIImage *)image isRender:(BOOL)isRender;
+ (UIImage *)extractLCDSegments:(UIImage *)image isRender:(BOOL)isRender;
+ (double)calculateStructuralSimilarity:(UIImage *)image1 with:(UIImage *)image2 
                             segments1:(UIImage *)segments1 segments2:(UIImage *)segments2;

@end
