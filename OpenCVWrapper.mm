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
#import <numeric>
using namespace cv;
#endif

@implementation OpenCVWrapper {
    dispatch_queue_t _processingQueue;
}

+ (void)initialize {
    if (self == [OpenCVWrapper class]) {
        // Initialize OpenCV in a thread-safe manner
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // Any global OpenCV initialization if needed
        });
    }
}

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
    
    UIImage *UIImageFromCVMat(Mat cvMat) {
        NSData *data = [NSData dataWithBytes:cvMat.data length:cvMat.elemSize() * cvMat.total()];
        
        CGColorSpaceRef colorSpace;
        if (cvMat.elemSize() == 1) {
            colorSpace = CGColorSpaceCreateDeviceGray();
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB();
        }
        
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        
        CGImageRef imageRef = CGImageCreate(cvMat.cols,
                                          cvMat.rows,
                                          8,
                                          8 * cvMat.elemSize(),
                                          cvMat.step[0],
                                          colorSpace,
                                          kCGImageAlphaNone|kCGBitmapByteOrderDefault,
                                          provider,
                                          NULL,
                                          false,
                                          kCGRenderingIntentDefault);
        
        UIImage *finalImage = [UIImage imageWithCGImage:imageRef];
        CGImageRelease(imageRef);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(colorSpace);
        
        return finalImage;
    }
    
    std::vector<KeyPoint> detectAndComputeFeatures(Mat img, Mat segments, Mat& descriptors, bool isRender) {
        // Create ORB detector with adaptive parameters
        int nfeatures = 3000;
        float scaleFactor = 1.1f;
        int nlevels = isRender ? 8 : 12;
        int edgeThreshold = isRender ? 10 : 15;
        int patchSize = isRender ? 15 : 21;
        int fastThreshold = isRender ? 10 : 20;
        
        cv::Ptr<cv::ORB> orb = cv::ORB::create(
            nfeatures,
            scaleFactor,
            nlevels,
            edgeThreshold,
            0,  // firstLevel
            3,  // WTA_K
            cv::ORB::HARRIS_SCORE,
            patchSize,
            fastThreshold
        );
        
        // Detect on both image and segments
        std::vector<KeyPoint> kp1, kp2;
        Mat desc1, desc2;
        
        orb->detectAndCompute(img, noArray(), kp1, desc1);
        orb->detectAndCompute(segments, noArray(), kp2, desc2);
        
        // Combine features
        std::vector<KeyPoint> keypoints;
        if (!desc1.empty() && !desc2.empty()) {
            keypoints.insert(keypoints.end(), kp1.begin(), kp1.end());
            keypoints.insert(keypoints.end(), kp2.begin(), kp2.end());
            vconcat(desc1, desc2, descriptors);
        } else if (!desc1.empty()) {
            keypoints = kp1;
            descriptors = desc1;
        } else if (!desc2.empty()) {
            keypoints = kp2;
            descriptors = desc2;
        }
        
        return keypoints;
    }
    
    double analyzeSpatialDistribution(const std::vector<KeyPoint>& keypoints, 
                                    const std::vector<DMatch>& matches,
                                    const cv::Size& imgSize) {
        if (matches.empty()) return 0.0;
        
        const int fineGridSize = 8;
        const int coarseGridSize = 4;
        
        Mat fineGrid = Mat::zeros(fineGridSize, fineGridSize, CV_32F);
        Mat coarseGrid = Mat::zeros(coarseGridSize, coarseGridSize, CV_32F);
        
        // Fill grids
        for (const auto& match : matches) {
            Point2f pt = keypoints[match.queryIdx].pt;
            
            // Fine grid
            int fx = std::min(int(pt.x * fineGridSize / imgSize.width), fineGridSize - 1);
            int fy = std::min(int(pt.y * fineGridSize / imgSize.height), fineGridSize - 1);
            fineGrid.at<float>(fy, fx) += 1;
            
            // Coarse grid
            int cx = std::min(int(pt.x * coarseGridSize / imgSize.width), coarseGridSize - 1);
            int cy = std::min(int(pt.y * coarseGridSize / imgSize.height), coarseGridSize - 1);
            coarseGrid.at<float>(cy, cx) += 1;
        }
        
        // Calculate coverage
        double fineCoverage = countNonZero(fineGrid) / double(fineGridSize * fineGridSize);
        double coarseCoverage = countNonZero(coarseGrid) / double(coarseGridSize * coarseGridSize);
        
        // Calculate evenness
        Scalar meanFine, stdFine, meanCoarse, stdCoarse;
        meanStdDev(fineGrid, meanFine, stdFine, fineGrid > 0);
        meanStdDev(coarseGrid, meanCoarse, stdCoarse, coarseGrid > 0);
        
        double fineEvenness = 1.0 - (stdFine[0] / (meanFine[0] + 1e-6));
        double coarseEvenness = 1.0 - (stdCoarse[0] / (meanCoarse[0] + 1e-6));
        
        // Calculate alignment score
        Mat rowSums, colSums;
        reduce(coarseGrid, rowSums, 1, REDUCE_SUM);
        reduce(coarseGrid, colSums, 0, REDUCE_SUM);
        
        Scalar rowMean, rowStd, colMean, colStd;
        meanStdDev(rowSums, rowMean, rowStd);
        meanStdDev(colSums, colMean, colStd);
        
        double rowVariation = rowStd[0] / (rowMean[0] + 1e-6);
        double colVariation = colStd[0] / (colMean[0] + 1e-6);
        double alignmentScore = std::max(0.0, 1.0 - std::min(rowVariation, colVariation));
        
        // Combine scores
        return 0.3 * fineCoverage +
               0.2 * coarseCoverage +
               0.2 * fineEvenness +
               0.1 * coarseEvenness +
               0.2 * alignmentScore;
    }
}

+ (BOOL)isDigitalRender:(UIImage *)image {
    static dispatch_queue_t opencvQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        opencvQueue = dispatch_queue_create("com.opencv.processing", DISPATCH_QUEUE_SERIAL);
    });
    
    __block BOOL result = NO;
    dispatch_sync(opencvQueue, ^{
        @try {
            Mat img = cvMatFromUIImage(image);
            
            // Edge detection
            Mat edges;
            Canny(img, edges, 100, 200);
            double edgeSharpness = mean(edges)[0] / 255.0;
            
            // Noise analysis
            Mat blur;
            GaussianBlur(img, blur, cv::Size(5,5), 0);
            Mat diff;
            absdiff(img, blur, diff);
            Scalar noiseMean, noiseStd;
            meanStdDev(diff, noiseMean, noiseStd);
            
            // Histogram analysis
            Mat hist;
            float range[] = {0, 256};
            const float* histRange = {range};
            int histSize = 256;
            calcHist(&img, 1, 0, Mat(), hist, 1, &histSize, &histRange);
            Scalar histMean, histStd;
            meanStdDev(hist, histMean, histStd);
            
            result = edgeSharpness > 0.1 && noiseStd[0] < 10 && histStd[0] > 1000;
        } @catch (...) {
            result = NO;
        }
    });
    
    return result;
}

+ (UIImage *)preprocessImage:(UIImage *)image isRender:(BOOL)isRender {
    Mat img = cvMatFromUIImage(image);
    Mat result;
    
    if (isRender) {
        // Simple contrast enhancement for renders
        cv::Ptr<CLAHE> clahe = createCLAHE(2.0, cv::Size(8,8));
        Mat enhanced;
        clahe->apply(img, enhanced);
        
        // Light edge enhancement
        Mat edges;
        Laplacian(enhanced, edges, CV_64F);
        convertScaleAbs(edges, edges);
        
        addWeighted(enhanced, 0.8, edges, 0.2, 0, result);
    } else {
        // Denoise and enhance for photos
        fastNlMeansDenoising(img, result, 10, 21);
        
        cv::Ptr<CLAHE> clahe = createCLAHE(3.0, cv::Size(8,8));
        clahe->apply(result, result);
        
        Mat blur;
        GaussianBlur(result, blur, cv::Size(0,0), 3);
        addWeighted(result, 1.5, blur, -0.5, 0, result);
        
        normalize(result, result, 0, 255, NORM_MINMAX);
    }
    
    return UIImageFromCVMat(result);
}

+ (UIImage *)extractLCDSegments:(UIImage *)image isRender:(BOOL)isRender {
    Mat img = cvMatFromUIImage(image);
    Mat binary;
    
    if (isRender) {
        threshold(img, binary, 127, 255, THRESH_BINARY);
    } else {
        adaptiveThreshold(img, binary, 255, ADAPTIVE_THRESH_GAUSSIAN_C,
                         THRESH_BINARY, 25, 15);
    }
    
    int kernelSize = isRender ? 3 : 5;
    Mat kernel = getStructuringElement(MORPH_RECT, cv::Size(kernelSize, kernelSize));
    
    morphologyEx(binary, binary, MORPH_CLOSE, kernel);
    
    if (!isRender) {
        morphologyEx(binary, binary, MORPH_OPEN, kernel);
        medianBlur(binary, binary, 5);
    }
    
    return UIImageFromCVMat(binary);
}

+ (double)calculateStructuralSimilarity:(UIImage *)image1 
                                 with:(UIImage *)image2 
                            segments1:(UIImage *)segments1 
                            segments2:(UIImage *)segments2 {
    Mat img1 = cvMatFromUIImage(image1);
    Mat img2 = cvMatFromUIImage(image2);
    Mat seg1 = cvMatFromUIImage(segments1);
    Mat seg2 = cvMatFromUIImage(segments2);
    
    // Calculate SSIM on original images
    Mat result;
    matchTemplate(img1, img2, result, TM_CCOEFF_NORMED);
    double ssimOrig = (result.at<float>(0,0) + 1.0) / 2.0;
    
    // Calculate SSIM on segments
    matchTemplate(seg1, seg2, result, TM_CCOEFF_NORMED);
    double ssimSeg = (result.at<float>(0,0) + 1.0) / 2.0;
    
    // Calculate histogram similarity
    Mat hist1, hist2;
    float range[] = {0, 256};
    const float* histRange = {range};
    int histSize = 256;
    calcHist(&img1, 1, 0, Mat(), hist1, 1, &histSize, &histRange);
    calcHist(&img2, 1, 0, Mat(), hist2, 1, &histSize, &histRange);
    
    double histSim = (compareHist(hist1, hist2, HISTCMP_CORREL) + 1.0) / 2.0;
    
    // Determine if both are renders
    bool bothRenders = [self isDigitalRender:image1] && [self isDigitalRender:image2];
    
    // Adjust weights based on image types
    double origWeight = bothRenders ? 0.2 : 0.4;
    double segWeight = bothRenders ? 0.6 : 0.4;
    double histWeight = 0.2;
    
    return origWeight * ssimOrig + segWeight * ssimSeg + histWeight * histSim;
}

+ (NSDictionary *)compareImages:(UIImage *)image1 with:(UIImage *)image2 {
    // Create a static serial queue for OpenCV operations
    static dispatch_queue_t opencvQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        opencvQueue = dispatch_queue_create("com.opencv.processing", DISPATCH_QUEUE_SERIAL);
    });
    
    // Perform OpenCV operations on the serial queue
    __block NSDictionary *result;
    dispatch_sync(opencvQueue, ^{
        @try {
            // Determine image types
            BOOL isRender1 = [self isDigitalRender:image1];
            BOOL isRender2 = [self isDigitalRender:image2];
            
            // Preprocess images
            UIImage *img1Proc = [self preprocessImage:image1 isRender:isRender1];
            UIImage *img2Proc = [self preprocessImage:image2 isRender:isRender2];
            
            UIImage *segments1 = [self extractLCDSegments:img1Proc isRender:isRender1];
            UIImage *segments2 = [self extractLCDSegments:img2Proc isRender:isRender2];
            
            // Calculate structural similarity
            double structuralSimilarity = [self calculateStructuralSimilarity:img1Proc 
                                                                       with:img2Proc
                                                                  segments1:segments1
                                                                  segments2:segments2];
            
            // Convert to OpenCV format
            Mat cvImg1 = cvMatFromUIImage(img1Proc);
            Mat cvImg2 = cvMatFromUIImage(img2Proc);
            Mat cvSeg1 = cvMatFromUIImage(segments1);
            Mat cvSeg2 = cvMatFromUIImage(segments2);
            
            // Detect features
            Mat desc1, desc2;
            std::vector<KeyPoint> kp1 = detectAndComputeFeatures(cvImg1, cvSeg1, desc1, isRender1);
            std::vector<KeyPoint> kp2 = detectAndComputeFeatures(cvImg2, cvSeg2, desc2, isRender2);
            
            if (kp1.empty() || kp2.empty() || desc1.empty() || desc2.empty()) {
                result = @{
                    @"score": @0.0,
                    @"matches": @0,
                    @"error": @"No features detected"
                };
                return;
            }
            
            // Match features
            cv::Ptr<cv::BFMatcher> matcher = cv::BFMatcher::create(NORM_HAMMING);
            std::vector<std::vector<DMatch>> knnMatches;
            matcher->knnMatch(desc1, desc2, knnMatches, 2);
            
            // Filter matches
            std::vector<DMatch> goodMatches;
            float ratioThresh = (isRender1 && isRender2) ? 0.8f : 0.85f;
            
            for (const auto& matchPair : knnMatches) {
                if (matchPair.size() == 2) {
                    if (matchPair[0].distance < ratioThresh * matchPair[1].distance) {
                        goodMatches.push_back(matchPair[0]);
                    }
                }
            }
            
            // Sort matches by distance
            std::sort(goodMatches.begin(), goodMatches.end());
            
            // Analyze spatial distribution
            double spatialScore = analyzeSpatialDistribution(kp1, goodMatches, cvImg1.size());
            
            // Calculate final score
            double rawScore = 0.0;
            if (!goodMatches.empty()) {
                // Quality score
                int numToConsider = std::min(100, (int)goodMatches.size());
                std::vector<float> distances;
                for (int i = 0; i < numToConsider; i++) {
                    distances.push_back(goodMatches[i].distance);
                }
                
                double avgDistance = std::accumulate(distances.begin(), distances.end(), 0.0) / distances.size();
                double maxDistance = (isRender1 && isRender2) ? 80.0 : 100.0;
                double qualityScore = std::max(0.0, std::min(1.0, (maxDistance - avgDistance) / maxDistance));
                
                // Quantity score
                double minExpectedMatches = 3000 * ((isRender1 && isRender2) ? 0.05 : 0.03);
                double quantityRatio = goodMatches.size() / minExpectedMatches;
                double quantityScore;
                
                if (quantityRatio <= 0.5) {
                    quantityScore = quantityRatio;
                } else if (quantityRatio <= 1.0) {
                    quantityScore = 0.5 + 0.5 * quantityRatio;
                } else {
                    quantityScore = std::min(1.0, 1.0 + 0.3 * log2(quantityRatio));
                }
                
                // Combine scores
                double weights[3] = {
                    (isRender1 && isRender2) ? 0.5 : 0.4,  // structural
                    (isRender1 && isRender2) ? 0.3 : 0.35, // quantity
                    (isRender1 && isRender2) ? 0.2 : 0.25  // quality
                };
                
                rawScore = weights[0] * structuralSimilarity +
                          weights[1] * quantityScore +
                          weights[2] * qualityScore;
                
                // Apply progressive scaling
                double power = (isRender1 && isRender2) ? 0.6 : 0.7;
                rawScore = 100.0 * pow(rawScore, power);
                
                // Apply bonuses
                if (rawScore > ((isRender1 && isRender2) ? 75.0 : 65.0)) {
                    rawScore *= 1.3;
                }
                
                rawScore = std::min(100.0, rawScore);
            }
            
            result = @{
                @"score": @(rawScore),
                @"matches": @(goodMatches.size()),
                @"structuralSimilarity": @(structuralSimilarity),
                @"spatialScore": @(spatialScore),
                @"isRender1": @(isRender1),
                @"isRender2": @(isRender2)
            };
        } @catch (NSException *exception) {
            result = @{
                @"score": @0.0,
                @"matches": @0,
                @"error": exception.description
            };
        } @catch (...) {
            result = @{
                @"score": @0.0,
                @"matches": @0,
                @"error": @"Unknown error in image processing"
            };
        }
    });
    
    return result;
}

@end
