//
//  CaptureSession.swift

//
//  Created by Tapas Behera on 7/9/18.
//  Copyright © 2018 com.acuant. All rights reserved.
//

import Foundation
import UIKit
import AVFoundation
import AcuantCommon
import AcuantImagePreparation

public class DocumentCaptureSession :AVCaptureSession,AVCaptureMetadataOutputObjectsDelegate,AVCaptureVideoDataOutputSampleBufferDelegate,AVCapturePhotoCaptureDelegate{
    private let context = CIContext()
    var frame : UIImage? = nil
    var croppedFrame : Image? = nil
    var stringValue : String? = nil
    var delegate : DocumentCaptureDelegate? = nil
    var captureDevice: AVCaptureDevice?
    private var captured = false
    private var cropping = false
    private var input : AVCaptureDeviceInput? = nil
    private var videoOutput : AVCaptureVideoDataOutput? = nil
    private var captureMetadataOutput : AVCaptureMetadataOutput? = nil
    private var frameDelegate:FrameAnalysisDelegate? = nil
    let stillImageOutput = AVCapturePhotoOutput()
    private var devicePreviewResolutionLongerSide = CaptureConstants.CAMERA_PREVIEW_LONGER_SIDE_STANDARD
    
    
    public class func getDocumentCaptureSession(delegate:DocumentCaptureDelegate?, frameDelegate: FrameAnalysisDelegate, captureDevice:AVCaptureDevice?)-> DocumentCaptureSession{
        return DocumentCaptureSession().getDocumentCaptureSession(delegate: delegate!, frameDelegate: frameDelegate,  captureDevice: captureDevice)
    }
    
    private func getDocumentCaptureSession(delegate:DocumentCaptureDelegate?, frameDelegate:FrameAnalysisDelegate, captureDevice: AVCaptureDevice?)->DocumentCaptureSession{
        self.delegate = delegate
        self.captureDevice = captureDevice
        self.frameDelegate = frameDelegate
        return self;
    }
    
    
    
    override public func startRunning() {
        DispatchQueue.main.async {
            super.startRunning()
            DispatchQueue(label: "come.acuant.avcapture.queue.0",qos:.userInteractive,attributes:.concurrent).async {
                self.automaticallyConfiguresApplicationAudioSession = false
                self.usesApplicationAudioSession = false
                if(self.captureDevice?.isFocusModeSupported(.continuousAutoFocus))! {
                    try! self.captureDevice?.lockForConfiguration()
                    self.captureDevice?.focusMode = .continuousAutoFocus
                    self.captureDevice?.unlockForConfiguration()
                }
                do {
                    self.input = try AVCaptureDeviceInput(device: self.captureDevice!)
                    if(self.canAddInput(self.input!)){
                        self.addInput(self.input!)
                    }
                } catch _ as NSError {
                    return
                }
                
                if(self.canSetSessionPreset(AVCaptureSession.Preset.hd4K3840x2160)){
                    self.sessionPreset = AVCaptureSession.Preset.hd4K3840x2160
                }else if(self.canSetSessionPreset(AVCaptureSession.Preset.photo)){
                    self.sessionPreset = AVCaptureSession.Preset.photo
                }else if(self.canSetSessionPreset(AVCaptureSession.Preset.high)){
                    self.sessionPreset = AVCaptureSession.Preset.high
                }
                
                if let formatDescription = self.captureDevice?.activeFormat.formatDescription {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
                    self.devicePreviewResolutionLongerSide = max(Int(dimensions.width),Int(dimensions.height))
                }
                
                self.videoOutput = AVCaptureVideoDataOutput()
                self.videoOutput?.alwaysDiscardsLateVideoFrames = true
                let frameQueue = DispatchQueue(label: "com.acuant.frame.queue",qos:.userInteractive,attributes:.concurrent)
                self.videoOutput?.setSampleBufferDelegate(self, queue: frameQueue)
                if(self.canAddOutput(self.videoOutput!)){
                    self.addOutput(self.videoOutput!)
                }
                
                if(self.canAddOutput(self.stillImageOutput)){
                    self.addOutput(self.stillImageOutput)
                }
                
                /* Check for metadata */
                self.captureMetadataOutput = AVCaptureMetadataOutput()
                let metadataQueue = DispatchQueue(label: "com.acuant.metadata.queue",qos:.userInteractive,attributes:.concurrent)
                self.captureMetadataOutput?.setMetadataObjectsDelegate(self, queue: metadataQueue)
                if (self.canAddOutput(self.captureMetadataOutput!)) {
                    self.addOutput(self.captureMetadataOutput!)
                    self.captureMetadataOutput?.metadataObjectTypes = [.pdf417]
                }
                DispatchQueue.main.async {
                    self.delegate?.didStartCaptureSession()
                }
            }
        }
    }
    
    
    // MARK: Sample buffer to UIImage conversion
    private func imageFromSampleBuffer(sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    private var frameCounter = 0
    private let DEFAULT_FRAME_THRESHOLD = 1
    private let FAST_FRAME_THRESHOLD = 3

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let frameQueue = DispatchQueue(label: "com.acuant.image.queue",attributes:.concurrent)
        frameQueue.async {
            self.frame = self.imageFromSampleBuffer(sampleBuffer: sampleBuffer)
            if(self.frame != nil && self.captured == false){
                if(self.cropping || self.captured){
                    return
                }
                self.cropping = true
                let startTime = CFAbsoluteTimeGetCurrent()
                self.croppedFrame = self.cropImage(image: self.frame!)
                let cropDuration = CFAbsoluteTimeGetCurrent() - startTime

                DispatchQueue.main.async{
                    let croppedImage = self.croppedFrame
                    var frameResult: FrameResult
                    
                    var MANDATORY_RESOLUTION_THRESHOLD = CaptureConstants.MANDATORY_RESOLUTION_THRESHOLD_DEFAULT
                    
                    if(croppedImage != nil && croppedImage?.image != nil){
                        
                        let aspectRatio = croppedImage!.aspectRatio
                        if(aspectRatio >= Float((1.0-CaptureConstants.ASPECT_RATIO_THRESHOLD/100.0)*CaptureConstants.ASPECT_RATIO_ID3) && aspectRatio<=Float((1.0+CaptureConstants.ASPECT_RATIO_THRESHOLD/100.0)*CaptureConstants.ASPECT_RATIO_ID3)){
                            MANDATORY_RESOLUTION_THRESHOLD = Int((Float(self.devicePreviewResolutionLongerSide)/Float(CaptureConstants.CAMERA_PREVIEW_LONGER_SIDE_STANDARD))*Float(CaptureConstants.MANDATORY_RESOLUTION_THRESHOLD_SMALL))
                            
                        }else{
                            MANDATORY_RESOLUTION_THRESHOLD = Int((Float(self.devicePreviewResolutionLongerSide)/Float(CaptureConstants.CAMERA_PREVIEW_LONGER_SIDE_STANDARD))*Float(CaptureConstants.MANDATORY_RESOLUTION_THRESHOLD_DEFAULT))
                        }
                        
                        
                    }
                    
                    if(croppedImage == nil || croppedImage!.error?.errorCode == AcuantErrorCodes.ERROR_CouldNotCrop || (croppedImage!.dpi) < CaptureConstants.NO_DOCUMENT_DPI_THRESHOLD ){
                        frameResult = FrameResult.NO_DOCUMENT
                        self.frameCounter = 0
                    }else if(croppedImage!.error?.errorCode == AcuantErrorCodes.ERROR_LowResolutionImage && (croppedImage!.dpi) < MANDATORY_RESOLUTION_THRESHOLD){
                        frameResult = FrameResult.SMALL_DOCUMENT
                        self.frameCounter = 0
                    }else if(croppedImage!.isCorrectAspectRatio == false){
                        frameResult = FrameResult.BAD_ASPECT_RATIO
                        self.frameCounter = 0
                    }else{
                        let threshold = self.getFrameMatchThreshold(cropDuration: cropDuration)
                        frameResult = FrameResult.GOOD_DOCUMENT
                        self.frameCounter += 1
                        
                        if(self.frameCounter > threshold){
                            self.captured = true
                            self.capturePhoto()             
                            DispatchQueue.main.async{
                                self.delegate?.readyToCapture()
                            }
                        }
                    }
                    self.frameDelegate?.onFrameAvailable(frameResult: frameResult)
                    self.cropping = false
                }
            }
        }
    }
    
    public func getFrameMatchThreshold(cropDuration: Double) -> Int{
        switch(cropDuration){
            case 0..<0.8:
                return FAST_FRAME_THRESHOLD
            default:
                return DEFAULT_FRAME_THRESHOLD
        }
    }
    
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            if(readableObject.stringValue == nil){
                return
            }
            self.stringValue = readableObject.stringValue
        }
    }
    
    func found2DBarcode(code: String,image:Image!) {
        if(self.captured == false){
            self.capturePhoto()
        }
    }
    
    
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Check if there is any error in capturing
        guard error == nil else {
            print("Fail to capture photo: \(String(describing: error))")
            return
        }
        
        // Check if the pixel buffer could be converted to image data
        guard let imageData = photo.fileDataRepresentation() else {
            print("Fail to convert pixel buffer")
            return
        }
        
        // Check if UIImage could be initialized with image data
        guard let capturedImage = UIImage.init(data: imageData , scale: 1.0) else {
            print("Fail to convert image data to UIImage")
            return
        }
        
        DispatchQueue.main.async{
            self.captureDevice = nil
            self.stopRunning()
            self.delegate?.documentCaptured(image: capturedImage, barcodeString:self.stringValue)
            self.delegate = nil
            self.frame = nil
        }
    }
    
    
    func capturePhoto() {
        let photoSetting = AVCapturePhotoSettings.init(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoSetting.isAutoStillImageStabilizationEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.stillImageOutput.capturePhoto(with: photoSetting, delegate: self)
        }
    }
    
    func cropImage(image:UIImage)->Image?{
        let croppingData  = CroppingData()
        croppingData.image = image
    
        let croppingOptions = CroppingOptions()
        croppingOptions.isHealthCard = false
        
        let croppedImage = AcuantImagePreparation.crop(options: croppingOptions, data: croppingData)
        return croppedImage
    }
    
}
