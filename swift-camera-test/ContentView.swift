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
    private let referenceImage: UIImage?
    private var guideRect: CGRect = .zero
    private let context = CIContext()
    private var currentDelegate: PhotoCaptureDelegate?
    
    @Published var isCameraAuthorized = false
    @Published var showPermissionAlert = false
    @Published var capturedImage: UIImage?
    @Published var previewImage: UIImage?
    @Published var matchQuality: Float = 0.0
    @Published var lastMatchDetails: [String: Any]?
    @Published var isAnalyzing = false
    @Published var isProcessing = false
    
    override init() {
        print("CameraViewModel: Initializing...")
        self.referenceImage = UIImage(named: "reference_image")
        super.init()
        
        guard referenceImage != nil else {
            print("Error: Reference image not found")
            return
        }
        
        checkCameraPermission()
    }
    
    private func checkCameraPermission() {
        print("Checking camera permission...")
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("Camera already authorized")
            setupCamera()
            isCameraAuthorized = true
        case .notDetermined:
            print("Requesting camera permission...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        print("Camera permission granted")
                        self?.setupCamera()
                        self?.isCameraAuthorized = true
                    } else {
                        print("Camera permission denied")
                        self?.showPermissionAlert = true
                    }
                }
            }
        case .denied:
            print("Camera permission denied")
            showPermissionAlert = true
        case .restricted:
            print("Camera access restricted")
            showPermissionAlert = true
        @unknown default:
            print("Unknown camera permission status")
            showPermissionAlert = true
        }
    }
    
    private func setupCamera() {
        print("Setting up camera...")
        session.beginConfiguration()
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                print("Cannot add camera input")
                return
            }
            guard session.canAddOutput(output) else {
                print("Cannot add photo output")
                return
            }
            
            session.addInput(input)
            session.addOutput(output)
            
            // Configure output settings
            if output.availablePhotoCodecTypes.contains(.jpeg) {
                output.maxPhotoQualityPrioritization = .quality
            }
            
            print("Camera setup successful")
            session.commitConfiguration()
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                print("Starting camera session...")
                self?.session.startRunning()
                print("Camera session started")
            }
        } catch {
            print("Error setting up camera: \(error.localizedDescription)")
        }
    }
    
    func captureAndAnalyze(completion: @escaping (Float) -> Void) {
        print("CameraViewModel: Starting capture process")
        guard !isProcessing else {
            print("CameraViewModel: Already processing, ignoring tap")
            return
        }
        
        guard session.isRunning else {
            print("CameraViewModel: Session not running")
            return
        }
        
        isProcessing = true
        
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .quality
        
        print("CameraViewModel: Configuring photo settings")
        
        // Create and retain the delegate
        let delegate = PhotoCaptureDelegate(guideRect: guideRect) { [weak self] image in
            print("CameraViewModel: Photo capture completed")
            guard let self = self else {
                print("CameraViewModel: Self is nil")
                return
            }
            
            // Clear the retained delegate
            self.currentDelegate = nil
            
            if let image = image {
                print("CameraViewModel: Image captured successfully")
                DispatchQueue.main.async {
                    self.previewImage = image
                    self.capturedImage = image
                    self.isProcessing = false
                    self.isAnalyzing = true
                    
                    // Start analysis immediately
                    self.analyzeImage(image, completion: completion)
                }
            } else {
                print("CameraViewModel: Failed to capture image")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    completion(0.0)
                }
            }
        }
        
        // Store the delegate
        currentDelegate = delegate
        
        print("CameraViewModel: Starting photo capture")
        output.capturePhoto(with: settings, delegate: delegate)
    }
    
    private func analyzeImage(_ image: UIImage, completion: @escaping (Float) -> Void) {
        print("CameraViewModel: Starting image analysis")
        guard let referenceImage = self.referenceImage else {
            print("CameraViewModel: Reference image not available")
            DispatchQueue.main.async {
                self.isAnalyzing = false
                completion(0.0)
            }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            print("CameraViewModel: Comparing images with OpenCV")
            guard let self = self else { return }
            
            autoreleasepool {
                if let result = OpenCVWrapper.compareImages(image, with: referenceImage) {
                    print("CameraViewModel: Comparison completed")
                    let score = (result["score"] as? NSNumber)?.floatValue ?? 0.0
                    let normalizedScore = score / 100.0
                    
                    // Convert dictionary to [String: Any]
                    let stringDict = result.reduce(into: [String: Any]()) { dict, pair in
                        if let key = pair.key as? String {
                            dict[key] = pair.value
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self.matchQuality = normalizedScore
                        self.lastMatchDetails = stringDict
                        self.isAnalyzing = false
                        completion(normalizedScore)
                    }
                } else {
                    print("CameraViewModel: Comparison failed")
                    DispatchQueue.main.async {
                        self.isAnalyzing = false
                        completion(0.0)
                    }
                }
            }
        }
    }
    
    func updateGuideRect(rect: CGRect) {
        guideRect = rect
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
        guard let referenceCGImage = referenceImage?.cgImage else { return 0.0 }
        
        // Convert CGImages to UIImages for OpenCV processing
        let croppedUIImage = UIImage(cgImage: croppedImage)
        let referenceUIImage = UIImage(cgImage: referenceCGImage)
        
        // Use enhanced ORB matching with preprocessing
        guard let result = OpenCVWrapper.compareImages(croppedUIImage, with: referenceUIImage) else {
            print("Error: Failed to get comparison results")
            return 0.0
        }
        
        // Extract score and normalize to 0-1 range
        let score = (result["score"] as? NSNumber)?.floatValue ?? 0.0
        let normalizedScore = score / 100.0
        
        // Log detailed matching information
        print("Match Details:")
        print("Score: \(String(format: "%.2f", score))%")
        print("Matches: \(result["matches"] as? Int ?? 0)")
        print("Structural Similarity: \(String(format: "%.3f", result["structuralSimilarity"] as? Double ?? 0.0))")
        print("Spatial Score: \(String(format: "%.3f", result["spatialScore"] as? Double ?? 0.0))")
        print("Is Reference Render: \(result["isRender1"] as? Bool ?? false)")
        print("Is Camera Render: \(result["isRender2"] as? Bool ?? false)")
        
        if let error = result["error"] as? String {
            print("Warning: \(error)")
        }
        
        return normalizedScore
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

class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let guideRect: CGRect
    private let completion: (UIImage?) -> Void
    
    init(guideRect: CGRect, completion: @escaping (UIImage?) -> Void) {
        print("PhotoCaptureDelegate: Initializing")
        self.guideRect = guideRect
        self.completion = completion
        super.init()
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput,
                    didFinishProcessingPhoto photo: AVCapturePhoto,
                    error: Error?) {
        print("PhotoCaptureDelegate: Processing photo output")
        
        if let error = error {
            print("PhotoCaptureDelegate: Error capturing photo - \(error.localizedDescription)")
            completion(nil)
            return
        }
        
        print("PhotoCaptureDelegate: Getting photo data")
        guard let imageData = photo.fileDataRepresentation() else {
            print("PhotoCaptureDelegate: Failed to get image data")
            completion(nil)
            return
        }
        
        print("PhotoCaptureDelegate: Creating UIImage")
        guard let image = UIImage(data: imageData) else {
            print("PhotoCaptureDelegate: Failed to create UIImage")
            completion(nil)
            return
        }
        
        print("PhotoCaptureDelegate: Processing successful, calling completion")
        completion(image)
    }
}

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var showingResults = false
    @State private var isButtonPressed = false
    
    var body: some View {
        ZStack {
            // Black background
            Color.black
                .edgesIgnoringSafeArea(.all)
            
            if viewModel.isCameraAuthorized {
                VStack {
                    // Camera preview or captured image
                    ZStack {
                        if let previewImage = viewModel.previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            CameraPreview(session: viewModel.session)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        GeometryReader { geometry in
                            let maxWidth = geometry.size.width * 0.8
                            let width = maxWidth
                            let height = width * (320.0 / 480.0)  // Maintain PM5544 aspect
                            let centerY = geometry.size.height / 2
                            
                            ZStack(alignment: .center) {
                                // Guide rectangle
                                Rectangle()
                                    .strokeBorder(
                                        viewModel.isAnalyzing ? Color.yellow : Color.white,
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
                        
                        // Status overlay
                        VStack {
                            if viewModel.isProcessing {
                                Text("Capturing...")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(10)
                            } else if viewModel.isAnalyzing {
                                Text("Analyzing...")
                                    .font(.headline)
                                    .foregroundColor(.yellow)
                                    .padding()
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(10)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
                    
                    Spacer()
                    
                    HStack {
                        // Reset button (only show when preview is visible)
                        if viewModel.previewImage != nil {
                            Button {
                                viewModel.previewImage = nil
                                viewModel.isAnalyzing = false
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .background(Color.gray)
                                    .clipShape(Circle())
                            }
                            .padding(.leading, 40)
                        }
                        
                        Spacer()
                        
                        // Capture button
                        Button {
                            print("Button tapped")
                            // Trigger haptic feedback
                            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                            impactFeedback.impactOccurred()
                            
                            // Visual button press animation
                            withAnimation(.easeInOut(duration: 0.1)) {
                                isButtonPressed = true
                            }
                            
                            // Reset button press state after a short delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation {
                                    isButtonPressed = false
                                }
                            }
                            
                            viewModel.captureAndAnalyze { score in
                                print("Analysis complete with score: \(score)")
                                showingResults = true
                            }
                        } label: {
                            Circle()
                                .fill(viewModel.isAnalyzing ? Color.yellow : Color.white)
                                .frame(width: 70, height: 70)
                                .scaleEffect(isButtonPressed ? 0.9 : 1.0)
                                .overlay(Circle().stroke(Color.gray, lineWidth: 2))
                                .overlay(
                                    Group {
                                        if viewModel.isAnalyzing || viewModel.isProcessing {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                                .scaleEffect(1.5)
                                        }
                                    }
                                )
                                .animation(.easeInOut(duration: 0.2), value: viewModel.isAnalyzing)
                                .animation(.easeInOut(duration: 0.2), value: viewModel.isProcessing)
                        }
                        .disabled(viewModel.isAnalyzing || viewModel.isProcessing)
                        .padding(.trailing, viewModel.previewImage != nil ? 40 : 0)
                        .padding(.bottom, 50)
                        
                        if viewModel.previewImage == nil {
                            Spacer()
                        }
                    }
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
        .sheet(isPresented: $showingResults) {
            ResultView(matchQuality: viewModel.matchQuality,
                      matchDetails: viewModel.lastMatchDetails,
                      capturedImage: viewModel.capturedImage)
        }
    }
}

struct ResultView: View {
    let matchQuality: Float
    let matchDetails: [String: Any]?
    let capturedImage: UIImage?
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Group {
                        if let capturedImage = capturedImage {
                            Image(uiImage: capturedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                        } else {
                            Text("No image captured")
                                .foregroundColor(.gray)
                                .frame(height: 200)
                        }
                    }
                    .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 15) {
                        ResultRow(title: "Match Score", 
                                value: String(format: "%.1f%%", matchQuality * 100),
                                color: matchScoreColor)
                        
                        if let details = matchDetails {
                            ResultRow(title: "Matches Found",
                                    value: "\(details["matches"] as? Int ?? 0)")
                            
                            ResultRow(title: "Structural Similarity",
                                    value: String(format: "%.1f%%", 
                                                (details["structuralSimilarity"] as? Double ?? 0) * 100))
                            
                            ResultRow(title: "Spatial Score",
                                    value: String(format: "%.1f%%", 
                                                (details["spatialScore"] as? Double ?? 0) * 100))
                            
                            if let error = details["error"] as? String {
                                Text(error)
                                    .foregroundColor(.red)
                                    .padding()
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Analysis Results")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
    
    private var matchScoreColor: Color {
        if matchQuality >= 0.7 {
            return .green
        } else if matchQuality >= 0.4 {
            return .yellow
        } else {
            return .red
        }
    }
}

struct ResultRow: View {
    let title: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .font(.body.monospaced())
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
