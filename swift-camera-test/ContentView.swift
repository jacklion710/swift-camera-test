//
//  ContentView.swift
//  swift-camera-test
//
//  Created by Jacob Leone on 6/19/25.
//

import SwiftUI
import AVFoundation

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
    
    @Published var isCameraAuthorized = false
    @Published var showPermissionAlert = false
    @Published var capturedImage: UIImage?
    @Published var showCapturedImage = false

    override init() {
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
              session.canAddInput(input), session.canAddOutput(output) else {
            print("Error setting up camera input/output")
            return
        }

        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
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
            print("Captured photo with size: \(data.count) bytes")
        }
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
                        
                        // Fixed overlay rectangle with 480:320 aspect ratio
                        GeometryReader { geometry in
                            let maxWidth = geometry.size.width * 0.8 // Use 80% of available width
                            let width = maxWidth
                            let height = width * (320.0/480.0) // maintain 480:320 aspect ratio
                            
                            Rectangle()
                                .strokeBorder(Color.gray.opacity(0.8), 
                                    style: StrokeStyle(
                                        lineWidth: 2,
                                        dash: [5]
                                    ))
                                .frame(width: width, height: height)
                                .position(x: geometry.size.width/2, y: geometry.size.height/2)
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
}

struct ContentView: View {
    var body: some View {
        CameraView()
    }
}

#Preview {
    ContentView()
}
