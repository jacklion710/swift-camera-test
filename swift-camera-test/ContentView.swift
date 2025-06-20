//
//  ContentView.swift
//  swift-camera-test
//
//  Created by Jacob Leone on 6/19/25.
//

import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

struct CameraPreview: UIViewRepresentable {
    class VideoPreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }
    }
    
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = VideoPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

class CameraViewModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let referenceImage: UIImage
    private var guideRect: CGRect = .zero
    private let context = CIContext()
    private var lastFrameTime: Date = Date()
    private let minimumFrameInterval: TimeInterval = 0.1 // 100ms between analyses
    
    // Pattern matching parameters
    private var imageMatchThreshold: Float = 0.4  // More realistic threshold
    private var recentMatches: [Float] = []
    private let matchBufferSize = 10
    
    @Published var isCameraAuthorized = false
    @Published var showPermissionAlert = false
    @Published var capturedImage: UIImage?
    @Published var showCapturedImage = false
    @Published var isMatchingTarget = false
    @Published var matchQuality: Float = 0.0
    
    override init() {
        // Load the reference image
        guard let image = UIImage(named: "reference_image") else {
            fatalError("Reference image not found")
        }
        self.referenceImage = image
        super.init()
        checkCameraPermission()
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
            isCameraAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                        self?.isCameraAuthorized = true
                    } else {
                        self?.showPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showPermissionAlert = true
        @unknown default:
            showPermissionAlert = true
        }
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output),
              session.canAddOutput(videoOutput) else {
            print("Error setting up camera input/output")
            return
        }
        
        session.addInput(input)
        session.addOutput(output)
        session.addOutput(videoOutput)
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
    
    func updateGuideRect(rect: CGRect) {
        guideRect = rect
    }
    
    private func analyzeFrame(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= minimumFrameInterval else { return }
        lastFrameTime = now
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cgImage = context.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))) else {
            return
        }
        
        // Convert guide rect to image coordinates
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let scaleX = imageWidth / UIScreen.main.bounds.width
        let scaleY = imageHeight / UIScreen.main.bounds.height
        
        let analysisRect = CGRect(
            x: guideRect.minX * scaleX,
            y: guideRect.minY * scaleY,
            width: guideRect.width * scaleX,
            height: guideRect.height * scaleY
        )
        
        // Extract the region of interest from the camera frame
        guard let croppedImage = cropImage(cgImage, to: analysisRect) else {
            DispatchQueue.main.async {
                self.matchQuality = 0.0
                self.isMatchingTarget = false
            }
            return
        }
        
        // Compare with reference image
        let matchScore = compareWithReference(croppedImage)
        
        // Update smoothed match quality
        recentMatches.append(matchScore)
        if recentMatches.count > matchBufferSize {
            recentMatches.removeFirst()
        }
        
        let smoothedQuality = recentMatches.reduce(0, +) / Float(recentMatches.count)
        
        DispatchQueue.main.async {
            self.matchQuality = smoothedQuality
            self.isMatchingTarget = smoothedQuality >= self.imageMatchThreshold
        }
    }
    
    private func cropImage(_ image: CGImage, to rect: CGRect) -> CGImage? {
        // Ensure the crop rect is within image bounds
        let clampedRect = CGRect(
            x: max(0, rect.minX),
            y: max(0, rect.minY),
            width: min(rect.width, CGFloat(image.width) - max(0, rect.minX)),
            height: min(rect.height, CGFloat(image.height) - max(0, rect.minY))
        )
        
        return image.cropping(to: clampedRect)
    }
    
    private func compareWithReference(_ croppedImage: CGImage) -> Float {
        guard let referenceCGImage = referenceImage.cgImage else { return 0.0 }
        
        // Resize both images to same size for comparison
        let targetSize = CGSize(width: 240, height: 160) // Small size for fast comparison
        
        guard let resizedCropped = resizeImage(croppedImage, to: targetSize),
              let resizedReference = resizeImage(referenceCGImage, to: targetSize) else {
            print("Failed to resize images")
            return 0.0
        }
        
        // Compare specific features of the PM5544 pattern
        let colorBarScore = compareColorBars(resizedCropped, reference: resizedReference)
        let structuralScore = compareStructuralFeatures(resizedCropped, reference: resizedReference)
        let edgeScore = compareEdgeFeatures(resizedCropped, reference: resizedReference)
        
        // More forgiving weighted combination
        let finalScore = (colorBarScore * 0.5) + (structuralScore * 0.3) + (edgeScore * 0.2)
        
        print("Scores - Color: \(String(format: "%.3f", colorBarScore)), Structural: \(String(format: "%.3f", structuralScore)), Edge: \(String(format: "%.3f", edgeScore)), Final: \(String(format: "%.3f", finalScore))")
        
        return finalScore
    }
    
    private func resizeImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                    width: Int(size.width),
                                    height: Int(size.height),
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        
        return context.makeImage()
    }
    
    private func compareColorBars(_ image: CGImage, reference: CGImage) -> Float {
        // Sample the top color bar region (where PM5544 color bars are located)
        let barRegion = CGRect(x: 0, y: 0, width: image.width, height: image.height / 3)
        
        var totalDifference: Float = 0.0
        var sampleCount = 0
        var maxDifference: Float = 0.0
        var minDifference: Float = 1.0
        
        // Sample multiple points across the color bar region
        for x in stride(from: barRegion.minX, through: barRegion.maxX - 1, by: max(1, barRegion.width / 15)) {
            for y in stride(from: barRegion.minY, through: barRegion.maxY - 1, by: max(1, barRegion.height / 3)) {
                let imageColor = samplePixel(image, at: CGPoint(x: x, y: y))
                let refColor = samplePixel(reference, at: CGPoint(x: x, y: y))
                
                let diff = colorDistance(imageColor, refColor)
                totalDifference += diff
                maxDifference = max(maxDifference, diff)
                minDifference = min(minDifference, diff)
                sampleCount += 1
            }
        }
        
        let avgDifference = sampleCount > 0 ? totalDifference / Float(sampleCount) : 1.0
        print("Color bars - Avg diff: \(String(format: "%.3f", avgDifference)), Min: \(String(format: "%.3f", minDifference)), Max: \(String(format: "%.3f", maxDifference)), Samples: \(sampleCount)")
        
        // More forgiving threshold - allow up to 0.8 average difference
        return max(0.0, 1.0 - (avgDifference / 0.8))
    }
    
    private func compareStructuralFeatures(_ image: CGImage, reference: CGImage) -> Float {
        // Compare the central area more generally
        let centerRegion = CGRect(
            x: image.width / 4, 
            y: image.height / 4, 
            width: image.width / 2, 
            height: image.height / 2
        )
        
        var totalDifference: Float = 0.0
        var sampleCount = 0
        
        // Sample in a grid pattern
        for x in stride(from: centerRegion.minX, through: centerRegion.maxX - 1, by: max(1, centerRegion.width / 10)) {
            for y in stride(from: centerRegion.minY, through: centerRegion.maxY - 1, by: max(1, centerRegion.height / 10)) {
                let imageColor = samplePixel(image, at: CGPoint(x: x, y: y))
                let refColor = samplePixel(reference, at: CGPoint(x: x, y: y))
                
                let diff = colorDistance(imageColor, refColor)
                totalDifference += diff
                sampleCount += 1
            }
        }
        
        let avgDifference = sampleCount > 0 ? totalDifference / Float(sampleCount) : 1.0
        print("Structural - Avg diff: \(String(format: "%.3f", avgDifference)), Samples: \(sampleCount)")
        
        // More forgiving threshold
        return max(0.0, 1.0 - (avgDifference / 0.8))
    }
    
    private func compareEdgeFeatures(_ image: CGImage, reference: CGImage) -> Float {
        // Just check overall brightness and contrast similarity
        var imageBrightness: Float = 0.0
        var refBrightness: Float = 0.0
        var sampleCount = 0
        
        // Sample a few points across the image
        for x in stride(from: 0, through: image.width - 1, by: max(1, image.width / 8)) {
            for y in stride(from: 0, through: image.height - 1, by: max(1, image.height / 8)) {
                let imageColor = samplePixel(image, at: CGPoint(x: x, y: y))
                let refColor = samplePixel(reference, at: CGPoint(x: x, y: y))
                
                imageBrightness += (imageColor.r + imageColor.g + imageColor.b) / 3.0
                refBrightness += (refColor.r + refColor.g + refColor.b) / 3.0
                sampleCount += 1
            }
        }
        
        if sampleCount > 0 {
            imageBrightness /= Float(sampleCount)
            refBrightness /= Float(sampleCount)
        }
        
        let brightnessDiff = abs(imageBrightness - refBrightness)
        print("Edge/Brightness - Image: \(String(format: "%.3f", imageBrightness)), Ref: \(String(format: "%.3f", refBrightness)), Diff: \(String(format: "%.3f", brightnessDiff))")
        
        // Very forgiving brightness comparison
        return max(0.0, 1.0 - (brightnessDiff / 0.5))
    }
    
    private func samplePixel(_ image: CGImage, at point: CGPoint) -> (r: Float, g: Float, b: Float) {
        let x = min(max(0, Int(point.x)), image.width - 1)
        let y = min(max(0, Int(point.y)), image.height - 1)
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * image.width
        var pixelData = [UInt8](repeating: 0, count: bytesPerPixel)
        
        guard let context = CGContext(data: &pixelData,
                                    width: 1,
                                    height: 1,
                                    bitsPerComponent: 8,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0, 0, 0)
        }
        
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        
        return (
            Float(pixelData[0]) / 255.0,
            Float(pixelData[1]) / 255.0,
            Float(pixelData[2]) / 255.0
        )
    }
    
    private func colorDistance(_ color1: (r: Float, g: Float, b: Float), _ color2: (r: Float, g: Float, b: Float)) -> Float {
        let rDiff = color1.r - color2.r
        let gDiff = color1.g - color2.g
        let bDiff = color1.b - color2.b
        return sqrt(rDiff * rDiff + gDiff * gDiff + bDiff * bDiff)
    }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                    didFinishProcessingPhoto photo: AVCapturePhoto,
                    error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error.localizedDescription)")
            return
        }
        
        if let data = photo.fileDataRepresentation(),
           let image = UIImage(data: data) {
            DispatchQueue.main.async { [weak self] in
                self?.capturedImage = image
                self?.showCapturedImage = true
            }
        }
    }
}

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        analyzeFrame(sampleBuffer)
    }
}

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    
    var body: some View {
        ZStack {
            // Black background
            Color.black
                .edgesIgnoringSafeArea(.all)
            
            if viewModel.isCameraAuthorized {
                VStack {
                    // Camera preview in a box
                    ZStack {
                        CameraPreview(session: viewModel.session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                        GeometryReader { geometry in
                            let maxWidth = geometry.size.width * 0.8
                            let width = maxWidth
                            let height = width * (320.0 / 480.0)  // Maintain PM5544 aspect
                            let centerY = geometry.size.height / 2
                            
                            ZStack(alignment: .center) {
                                // Match quality indicator
                                Text(matchQualityText)
                                    .foregroundColor(matchQualityColor)
                                    .font(.headline)
                                    .padding(8)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(8)
                                    .offset(y: -(height / 2 + 40)) // Position above rectangle
                                
                                // Guide rectangle
                                Rectangle()
                                    .strokeBorder(
                                        viewModel.isMatchingTarget ? Color.green : Color.gray.opacity(0.8),
                                        style: StrokeStyle(
                                            lineWidth: 2,
                                            dash: [5]
                                        ))
                                    .frame(width: width, height: height)
                            }
                            .position(x: geometry.size.width / 2, y: centerY)
                            .onAppear {
                                viewModel.updateGuideRect(rect: CGRect(
                                    x: (geometry.size.width - width) / 2,
                                    y: (geometry.size.height - height) / 2,
                                    width: width,
                                    height: height
                                ))
                            }
                            .onChange(of: geometry.size) { _ in
                                viewModel.updateGuideRect(rect: CGRect(
                                    x: (geometry.size.width - width) / 2,
                                    y: (geometry.size.height - height) / 2,
                                    width: width,
                                    height: height
                                ))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
                    
                    Spacer()
                    
                    // Capture button
                    Button(action: {
                        viewModel.capturePhoto()
                    }) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 70, height: 70)
                            .overlay(Circle().stroke(Color.gray, lineWidth: 2))
                    }
                    .padding(.bottom, 50)
                }
            } else {
                VStack {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("Camera Access Required")
                        .font(.title2)
                        .padding()
                    Text("Please enable camera access in Settings to use this app.")
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .alert("Camera Permission Required", isPresented: $viewModel.showPermissionAlert) {
            Button("Settings") {
                if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsUrl)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This app needs camera access to take photos. Please enable it in Settings.")
        }
        .sheet(isPresented: $viewModel.showCapturedImage) {
            if let image = viewModel.capturedImage {
                VStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .padding()
                    
                    Button("Done") {
                        viewModel.showCapturedImage = false
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .background(Color.black)
            }
        }
    }
    
    private var matchQualityText: String {
        let percentage = Int(viewModel.matchQuality * 100)
        if viewModel.isMatchingTarget {
            return "✓ Pattern Matched! (\(percentage)%)"
        } else if percentage > 0 {
            return "Align LCD Screen (\(percentage)%)"
        } else {
            return "Align LCD Screen"
        }
    }
    
    private var matchQualityColor: Color {
        if viewModel.isMatchingTarget {
            return .green
        } else if viewModel.matchQuality > 0.5 {
            return .yellow
        } else {
            return .gray
        }
    }
}

struct ContentView: View {
    var body: some View {
        CameraView()
    }
}

#Preview {
    ContentView()
}
