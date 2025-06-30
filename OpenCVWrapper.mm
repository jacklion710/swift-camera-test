//
//  OpenCVWrapper.m
//  swift-camera-test
//
//  Created by Jacob Leone on 6/30/25.
//

#import "OpenCVWrapper.h"
#ifdef __cplusplus
#import <opencv2/opencv.hpp>
#import <opencv2/features2d.hpp>
using namespace cv;
#endif

@implementation OpenCVWrapper

namespace {
    Mat cvMatFromUIImage(UIImage *image) {
        CGColorSpaceRef colorSpace = CGImageGetColorSpace(image.CGImage);
        CGFloat cols = image.size.width;
        CGFloat rows = image.size.height;
        
        Mat cvMat(rows, cols, CV_8UC4);
        
        CGContextRef contextRef = CGBitmapContextCreate(cvMat.data,
                                                       cols,
                                                       rows,
                                                       8,
                                                       cvMat.step[0],
                                                       colorSpace,
                                                       kCGImageAlphaNoneSkipLast |
                                                       kCGBitmapByteOrderDefault);
        
        CGContextDrawImage(contextRef, CGRectMake(0, 0, cols, rows), image.CGImage);
        CGContextRelease(contextRef);
        
        Mat grayMat;
        cvtColor(cvMat, grayMat, COLOR_RGBA2GRAY);
        
        return grayMat;
    }
}

+ (double)matchImagesORB:(UIImage *)image1 with:(UIImage *)image2 {
#ifdef __cplusplus
    try {
        // Convert UIImages to cv::Mat
        Mat img1 = cvMatFromUIImage(image1);
        Mat img2 = cvMatFromUIImage(image2);
        
        // Create ORB detector
        cv::Ptr<cv::ORB> orb = cv::ORB::create(500);
        
        // Detect keypoints and compute descriptors
        std::vector<KeyPoint> keypoints1, keypoints2;
        Mat descriptors1, descriptors2;
        
        orb->detectAndCompute(img1, noArray(), keypoints1, descriptors1);
        orb->detectAndCompute(img2, noArray(), keypoints2, descriptors2);
        
        // If no keypoints found, return 0
        if (keypoints1.empty() || keypoints2.empty() || 
            descriptors1.empty() || descriptors2.empty()) {
            return 0.0;
        }
        
        // Match descriptors using Hamming distance
        cv::Ptr<cv::BFMatcher> matcher = cv::BFMatcher::create(NORM_HAMMING);
        std::vector<DMatch> matches;
        matcher->match(descriptors1, descriptors2, matches);
        
        if (matches.empty()) {
            return 0.0;
        }
        
        // Calculate max and min distances
        double minDist = std::numeric_limits<double>::max();
        for (const auto& match : matches) {
            double dist = match.distance;
            if (dist < minDist) minDist = dist;
        }
        
        // Keep only good matches
        std::vector<DMatch> goodMatches;
        for (const auto& match : matches) {
            if (match.distance <= std::max(2.0 * minDist, 30.0)) {
                goodMatches.push_back(match);
            }
        }
        
        // Calculate matching score
        double matchScore = static_cast<double>(goodMatches.size()) / 
                          std::max(static_cast<double>(keypoints1.size()),
                                 static_cast<double>(keypoints2.size()));
        
        return matchScore;
    } catch (const cv::Exception& e) {
        NSLog(@"OpenCV Error: %s", e.what());
        return 0.0;
    } catch (...) {
        NSLog(@"Unknown error in ORB matching");
        return 0.0;
    }
#else
    return 0.0;
#endif
}

@end
