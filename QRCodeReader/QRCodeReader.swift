/*
 * QRCodeReader.swift
 *
 * Copyright 2014-present Yannick Loriot.
 * http://yannickloriot.com
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

import UIKit
import AVFoundation

/// Reader object base on the `AVCaptureDevice` to read / scan 1D and 2D codes.
public final class QRCodeReader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  private let sessionQueue         = DispatchQueue(label: "session queue")
  private let metadataObjectsQueue = DispatchQueue(label: "com.yannickloriot.qr", attributes: [], target: nil)

  var defaultDevice: AVCaptureDevice? = AVCaptureDevice.default(for: .video)
  var frontDevice: AVCaptureDevice?  = {
    for device in AVCaptureDevice.devices(for: AVMediaType.video) {
      if device.position == AVCaptureDevice.Position.front {
        return device
      }
    }

    return nil
  }()

  lazy var defaultDeviceInput: AVCaptureDeviceInput? = {
    guard let defaultDevice = defaultDevice else {
      return nil
    }
    return try? AVCaptureDeviceInput(device: defaultDevice)
  }()

  lazy var frontDeviceInput: AVCaptureDeviceInput?  = {
    if let _frontDevice = self.frontDevice {
      return try? AVCaptureDeviceInput(device: _frontDevice)
    }

    return nil
  }()

  var metadataOutput = AVCaptureMetadataOutput()
  var session        = AVCaptureSession()

  var stopScanningWithoutStopingCamera = false
  
  // MARK: - Managing the Properties

  /// CALayer that you use to display video as it is being captured by an input device.
  public lazy var previewLayer: AVCaptureVideoPreviewLayer = {
    return AVCaptureVideoPreviewLayer(session: self.session)
  }()

  /// An array of strings identifying the types of metadata objects to process.
  public let metadataObjectTypes: [AVMetadataObject.ObjectType]

  // MARK: - Managing the Code Discovery

  /// Flag to know whether the scanner should stop scanning when a code is found.
  public var stopScanningWhenCodeIsFound: Bool = true

  /// Block is executed when a metadata object is found.
  public var didFindCodeBlock: ((QRCodeReaderResult) -> Void)?

  // MARK: - Creating the Code Reader

  /**
   Initializes the code reader with the QRCode metadata type object.
   */
  public convenience override init() {
    self.init(metadataObjectTypes: [AVMetadataObject.ObjectType.qr])
  }

  /**
   Initializes the code reader with an array of metadata object types.

   - parameter metadataObjectTypes: An array of strings identifying the types of metadata objects to process.
   */
  public init(metadataObjectTypes types: [AVMetadataObject.ObjectType]) {
    metadataObjectTypes = types

    super.init()

    sessionQueue.async {
      self.configureDefaultComponents()
    }
  }
  
  /**
   limit visible area of the previewLayer to accept barcode input (ignore the rest)
  */
  func limitRectOfInterest(_ rect: CGRect) {
    let visibleMetadataOutputRect: CGRect = previewLayer.metadataOutputRectConverted(fromLayerRect: rect/*previewLayer.bounds*/)
    metadataOutput.rectOfInterest = visibleMetadataOutputRect
    //print("Set scan limit of interest : \(rect) <=> \(visibleMetadataOutputRect)")
  }
  
  // MARK: - Initializing the AV Components

  fileprivate func configureDefaultComponents() {
    for output in session.outputs {
      session.removeOutput(output)
    }
    for input in session.inputs {
      session.removeInput(input)
    }

    session.addOutput(metadataOutput)

    if let _defaultDeviceInput = defaultDeviceInput {
      session.addInput(_defaultDeviceInput)
    }

    metadataOutput.setMetadataObjectsDelegate(self, queue: metadataObjectsQueue)
    previewLayer.videoGravity          = AVLayerVideoGravity.resizeAspectFill

    let allTypes = Set(metadataOutput.availableMetadataObjectTypes)
    let filtered = metadataObjectTypes.filter { (mediaType) -> Bool in
      allTypes.contains(mediaType)
    }
    metadataOutput.metadataObjectTypes = filtered
    session.commitConfiguration()
  }

  /// Switch between the back and the front camera.
  public func switchDeviceInput() {
    if let _frontDeviceInput = frontDeviceInput {
      session.beginConfiguration()

      if let _currentInput = session.inputs.first as? AVCaptureDeviceInput {
        session.removeInput(_currentInput)

        let newDeviceInput = (_currentInput.device.position == .front) ? defaultDeviceInput : _frontDeviceInput
        if let newDeviceInput = newDeviceInput {
          session.addInput(newDeviceInput)
        }
      }

      session.commitConfiguration()
    }
  }

  // MARK: - Controlling Reader

  /**
   Starts scanning the codes.

   *Notes: if `stopScanningWhenCodeIsFound` is sets to true (default behaviour), each time the scanner found a code it calls the `stopScanning` method.*
   */
  public func startScanning(_ onlyCamera: Bool) {
    print("start scanning")
    sessionQueue.async {
      if !self.session.isRunning {
        if onlyCamera {
          self.session.removeOutput(self.metadataOutput)
        }
        self.session.startRunning()
      }
      if self.stopScanningWithoutStopingCamera && !onlyCamera {
        if self.session.canAddOutput(self.metadataOutput) {
          self.session.addOutput(self.metadataOutput)
        }
      }
    }
  }

  /// Stops scanning the codes.
  public func stopScanning() {
    sessionQueue.async {
      if self.stopScanningWithoutStopingCamera {
        self.session.removeOutput(self.metadataOutput)
      } else {
        if self.session.isRunning {
          self.session.stopRunning()
        }
      }
    }
  }

  /**
   Indicates whether the session is currently running.

   The value of this property is a Bool indicating whether the receiver is running.
   Clients can key value observe the value of this property to be notified when
   the session automatically starts or stops running.
   */
  public var running: Bool {
    get {
      return session.isRunning
    }
  }

  /**
   Returns true whether a front device is available.

   - returns: true whether the device has a front device.
   */
  public func hasFrontDevice() -> Bool {
    return frontDevice != nil
  }

  /**
   Returns true whether a torch is available.

   - returns: true if a torch is available.
   */
  public func isTorchAvailable() -> Bool {
    return defaultDevice?.isTorchAvailable ?? false
  }

  /**
   Toggles torch on the default device.
   */
  public func toggleTorch() {
    do {
      try defaultDevice?.lockForConfiguration()

      defaultDevice?.torchMode = AVCaptureDevice.TorchMode.on == .on ? .off : .on

      defaultDevice?.unlockForConfiguration()
    }
    catch _ { }
  }

  // MARK: - Managing the Orientation

  /**
   Returns the video orientation corresponding to the given device orientation.

   - parameter orientation: The orientation of the app's user interface.
   - parameter supportedOrientations: The supported orientations of the application.
   - parameter fallbackOrientation: The video orientation if the device orientation is FaceUp or FaceDown.
   */
  public class func videoOrientationFromDeviceOrientation(_ orientation: UIDeviceOrientation, withSupportedOrientations supportedOrientations: UIInterfaceOrientationMask, fallbackOrientation: AVCaptureVideoOrientation? = nil) -> AVCaptureVideoOrientation {
    let result: AVCaptureVideoOrientation

    switch (orientation, fallbackOrientation) {
    case (.landscapeLeft, _):
      result = .landscapeRight
    case (.landscapeRight, _):
      result = .landscapeLeft
    case (.portrait, _):
      result = .portrait
    case (.portraitUpsideDown, _):
      result = .portraitUpsideDown
    case (_, .some(let orientation)):
      result = orientation
    default:
      result = .portrait
    }

    if supportedOrientations.contains(orientationMaskWithVideoOrientation(result)) {
      return result
    }
    else if let orientation = fallbackOrientation, supportedOrientations.contains(orientationMaskWithVideoOrientation(orientation)) {
      return orientation
    }
    else if supportedOrientations.contains(.portrait) {
      return .portrait
    }
    else if supportedOrientations.contains(.landscapeLeft) {
      return .landscapeLeft
    }
    else if supportedOrientations.contains(.landscapeRight) {
      return .landscapeRight
    }
    else {
      return .portraitUpsideDown
    }
  }

  class func orientationMaskWithVideoOrientation(_ orientation: AVCaptureVideoOrientation) -> UIInterfaceOrientationMask {
    switch orientation {
    case .landscapeLeft:
      return .landscapeLeft
    case .landscapeRight:
      return .landscapeRight
    case .portrait:
      return .portrait
    case .portraitUpsideDown:
      return .portraitUpsideDown
    }
  }

  // MARK: - Checking the Reader Availabilities

  /**
   Checks whether the reader is available.

   - returns: A boolean value that indicates whether the reader is available.
   */
  public class func isAvailable() -> Bool {
    guard let captureDevice = AVCaptureDevice.default(for: .video) else { return false }

    return (try? AVCaptureDeviceInput(device: captureDevice)) != nil
  }


  /**
   Checks and return whether the given metadata object types are supported by the current device.

   - parameter metadataTypes: An array of strings identifying the types of metadata objects to check.

   - returns: A boolean value that indicates whether the device supports the given metadata object types.
   */
  public class func supportsMetadataObjectTypes(_ metadataTypes: [AVMetadataObject.ObjectType]? = nil) -> Bool {
    if !isAvailable() {
      return false
    }

    // Setup components
    guard let captureDevice = AVCaptureDevice.default(for: .video) else {
      return false
    }
    let deviceInput   = try! AVCaptureDeviceInput(device: captureDevice)
    let output        = AVCaptureMetadataOutput()
    let session       = AVCaptureSession()

    session.addInput(deviceInput)
    session.addOutput(output)

    var metadataObjectTypes = metadataTypes

    if metadataObjectTypes == nil || metadataObjectTypes?.count == 0 {
      // Check the QRCode metadata object type by default
      metadataObjectTypes = [AVMetadataObject.ObjectType.qr]
    }

    for metadataObjectType in metadataObjectTypes! {
      if !output.availableMetadataObjectTypes.contains(where: { $0 == metadataObjectType }) {
        return false
      }
    }
    return true
  }

  public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    print("did I scan shit?")
      sessionQueue.async { [weak self] in
      guard let weakSelf = self else { return }

        for current in metadataObjects {
        print("scanned QRCode \(current)")
        if let _readableCodeObject = current as? AVMetadataMachineReadableCodeObject {
          if _readableCodeObject.stringValue != nil {
            if weakSelf.metadataObjectTypes.contains(_readableCodeObject.type) {
              guard weakSelf.session.isRunning, let sVal = _readableCodeObject.stringValue else { return }

              if weakSelf.stopScanningWhenCodeIsFound {
                  weakSelf.stopScanning()
              }

              let scannedResult = QRCodeReaderResult(value: sVal, metadataType:_readableCodeObject.type.rawValue)
               DispatchQueue.main.async {
                weakSelf.didFindCodeBlock?(scannedResult)
              }
            }
          }
        }
      }
    }
  }
}
