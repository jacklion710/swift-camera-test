//
//  OpenCVWrapper.h
//  swift-camera-test
//
//  Created by Jacob Leone on 6/30/25.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface OpenCVWrapper : NSObject
+ (double)matchImagesORB:(UIImage *)image1 with:(UIImage *)image2;
@end
