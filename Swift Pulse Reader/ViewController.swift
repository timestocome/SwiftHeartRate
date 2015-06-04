//
//  ViewController.swift
//  Swift Pulse Reader
//
//  Created by Linda Cobb on 5/29/15.
//  Copyright (c) 2015 TimesToCome Mobile. All rights reserved.
//




import UIKit
import Foundation
import AVFoundation
import QuartzCore
import CoreMedia
import Accelerate




class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate
{

    
    // UI stuff
    @IBOutlet var graphView: GraphView!
    @IBOutlet var timeLabel: UILabel!
    @IBOutlet var pulseLabel: UILabel!
    @IBOutlet var HFBandLabel: UILabel!
    @IBOutlet var LFBandLabel: UILabel!
    var timeElapsedStart:NSDate!
        
    
    // camera setup
    var cameraOn = false
    var stopUpdates = false

    var session:AVCaptureSession!
    var videoDevice:AVCaptureDevice!
    var videoInput:AVCaptureDeviceInput!
    var dataOutput:AVCaptureVideoDataOutput!
    
    
    // used to compute frames per second
    var newDate:NSDate = NSDate()
    var oldDate:NSDate = NSDate()
    
    
    // needed to init image context
    var context:CIContext!
    
   
    
    // FFT setup stuff
    let windowSize = 256                // granularity of the measurement, error
    var log2n:vDSP_Length = 0
    let windowSizeOverTwo = 128         // for fft
    var fps:Float = 15.0                // fps === hz
    var setup:COpaquePointer!

    
    // collects data from image and stores for fft
    var dataCount = 0           // tracks how many data points we have ready for fft
    var fftLoopCount = 0        // how often we grab data between fft calls
    var inputSignal:[Float] = Array(count: 256, repeatedValue: 0.0)
    let loopCount = 64          // number of data points between fft calls ~ 1 seconds = 15 frames, use a power of two

   
    
    
    

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // set up memory for FFT
        log2n = vDSP_Length(log2(Double(windowSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        
        // init graphs
        graphView.setupGraphView()

    }
    
    
    
    
    
    // set up to grab live images from the camera
    func setupCaptureSession () {
        
        var error: NSError?
        
        // inputs - find and use back facing camera
        let videoDevices = AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo)
        
        for device in videoDevices{
            if device.position == AVCaptureDevicePosition.Back {
                videoDevice = device as! AVCaptureDevice
            }
        }
        
        videoInput = AVCaptureDeviceInput(device: videoDevice, error: &error )
        
        // output
        dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        let sessionQueue = dispatch_queue_create("AVSessionQueue", DISPATCH_QUEUE_SERIAL)
        dataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        
        
        
        // set up session
        session = AVCaptureSession()

        // measure pulse from 40-230bpm = ~.5 - 4bps * 2 to remove aliasing need 8 frames/sec minimum
        // presetLow captures 15 fps with light on, 7 with light off
        session.sessionPreset = AVCaptureSessionPresetLow
        
        // turn on light
        session.beginConfiguration()
            videoDevice.lockForConfiguration(&error)
                videoDevice.setTorchModeOnWithLevel(AVCaptureMaxAvailableTorchLevel, error: &error)
            videoDevice.unlockForConfiguration()
        session.commitConfiguration()
        
        
        session.addInput(videoInput)
        session.addOutput(dataOutput)
        
        session.startRunning()

    }
    
    
    
    
    // grab each camera image, 
    // split into red, green, blue pixels, 
    // compute average red, green blue pixel value per frame
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        
        
        // calculate our actual fps
        newDate = NSDate()
        fps = 1.0/Float(newDate.timeIntervalSinceDate(oldDate))
        oldDate = newDate
        

        // get the image from the camera
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        
        // lock buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        
        // grab image info
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        // get pointer to the pixel array
        var src_buff = CVPixelBufferGetBaseAddress(imageBuffer)
        var dataBuffer = UnsafeMutablePointer<UInt8>(src_buff)
        
        // unlock buffer
        CVPixelBufferUnlockBaseAddress(imageBuffer, 0)
        
        // image data - should probably compute this once somewhere else
        let height = CVPixelBufferGetHeight(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let numberOfPixels = width * height
    
        
        // compute the brightness for reg, green, blue and total
        
        // pull out color values from pixels ---  image is BGRA
        var greenVector:[Float] = Array(count: numberOfPixels, repeatedValue: 0.0)
        var blueVector:[Float] = Array(count: numberOfPixels, repeatedValue: 0.0)
        var redVector:[Float] = Array(count: numberOfPixels, repeatedValue: 0.0)
        
        vDSP_vfltu8(dataBuffer, 4, &blueVector, 1, vDSP_Length(numberOfPixels))
        vDSP_vfltu8(dataBuffer+1, 4, &greenVector, 1, vDSP_Length(numberOfPixels))
        vDSP_vfltu8(dataBuffer+2, 4, &redVector, 1, vDSP_Length(numberOfPixels))
        

        
        // compute average per color
        var redAverage:Float = 0.0
        var blueAverage:Float = 0.0
        var greenAverage:Float = 0.0
        
        vDSP_meamgv(&redVector, 1, &redAverage, vDSP_Length(numberOfPixels))
        vDSP_meamgv(&greenVector, 1, &greenAverage, vDSP_Length(numberOfPixels))
        vDSP_meamgv(&blueVector, 1, &blueAverage, vDSP_Length(numberOfPixels))
        
        
        dispatch_async(dispatch_get_main_queue()){
            self.collectDataForFFT(redAverage, green: greenAverage, blue: blueAverage)
            self.graphView.addX(redAverage)
        }
    }
    
    
    // grab data points from image
    // stuff the data points into an array
    // call fft after we collect a window worth of data points
    //
    // one color is plenty for heart rate
    // others are here only as setup for future projects
    func collectDataForFFT( red: Float, green: Float, blue: Float ){
    
        // first fill up array
        if  dataCount < windowSize {
            inputSignal[dataCount] = red
            dataCount++
            
        // then pop oldest off top push newest onto end
        }else{
            
            inputSignal.removeAtIndex(0)
            inputSignal.append(red)
        }
        
        
        
        // call fft once per second
        if  fftLoopCount > Int(fps) {
            fftLoopCount = 0;
            FFT()
            
        }else{ fftLoopCount++; }

    
    }
    
    
    
    
    
    func FFT(){
        
        
        // parse data input into complex vector
        var zerosR = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var zerosI = [Float](count: windowSizeOverTwo, repeatedValue: 0.0)
        var cplxData = DSPSplitComplex( realp: &zerosR, imagp: &zerosI )
        
        var xAsComplex = UnsafePointer<DSPComplex>( inputSignal.withUnsafeBufferPointer { $0.baseAddress } )
        vDSP_ctoz( xAsComplex, 2, &cplxData, 1, vDSP_Length(windowSizeOverTwo) )
        
        
        
        //perform fft
        vDSP_fft_zrip( setup, &cplxData, 1, log2n, FFTDirection(kFFTDirection_Forward) )
        
        
        
        
        
        
        //calculate power
        var powerVector = [Float](count: windowSize, repeatedValue: 0.0)
        vDSP_zvmags(&cplxData, 1, &powerVector, 1, vDSP_Length(windowSizeOverTwo))
        
        
        // find peak power and bin
        var power = 0.0 as Float
        var bin = 0 as vDSP_Length
        
        
        
        ///////////////////////////////////////////////////////////////////
        ////////////   calculate heart rate, ie pulse  ////////////////////
        // skip hr under 35 when calculating power, then adjust bin count
        let minHeartRate = 10       // 10 * bin size of 3.5 is 35
        // skip hr over ~300 as junk
        let maxHeartRate = Double(windowSizeOverTwo) / 2.0
        vDSP_maxvi(&powerVector+minHeartRate, 1, &power, &bin, vDSP_Length(maxHeartRate))
        bin += 10
        
        
        // make sure we have at least 15 secs of data before pushing to user
        let timeElapsed = NSDate().timeIntervalSinceDate(timeElapsedStart)
        timeLabel.text = NSString(format: "Seconds: %d", Int(timeElapsed)) as String

        
        if timeElapsed > 15.0 {     // collect enough data to get a good reading
    
            // push the data to the user
            // fps == hz
            let binSize = fps * 60.0 / Float(windowSize)
            let errorSize = fps * 60.0 / Float(windowSize)
            var bpm = Float(bin) * fps * 60.0 / Float(windowSize)
            
            
            // do we have another way to count peaks per minute?
            // find derivative, count sign changes?
            let dataPointsPerFiveSeconds = Int(fps * 10)
        
            var x1:[Float] = inputSignal
            x1.removeAtIndex(0)

            var dx:[Float] = Array(count: dataPointsPerFiveSeconds, repeatedValue: 0.0)
            vDSP_vsub(inputSignal, 1, x1, 1, &dx, 1, vDSP_Length(dataPointsPerFiveSeconds))
        
            var indexCrossing:vDSP_Length = 0
            var numberOfCrossings:vDSP_Length = 0
            
            vDSP_nzcros(dx, 1, vDSP_Length(dataPointsPerFiveSeconds), &indexCrossing, &numberOfCrossings, vDSP_Length(dataPointsPerFiveSeconds))
            var heartRate = Int(numberOfCrossings / 2) * 6      // 10 * 6 = 60 seconds, two crossings per peak
            
            
            println("fft says \(bpm), derivative says \(heartRate)")
            
            // sanity check data
            let test:Int = heartRate - Int(bpm)
            if abs(test) <= 5 {
                var combinedScores = abs( (heartRate + Int(bpm)) / 2 )
                pulseLabel.text = NSString(format: "Locked: Heart rate: %d  +/- 2", Int(bpm)) as String
            }else{
                pulseLabel.text = NSString(format: "Between %d - %d", Int(bpm), heartRate) as String
            }
            
        }else{
            pulseLabel.text = "collecting data...."
        }
    }
    
    
    
    
    
    
    
    @IBAction func stop(){
        
        stopUpdates = true
        session.stopRunning()
    }
    
    
    
    @IBAction func start(){
        
        stopUpdates = false
        cameraOn = true
        
        timeElapsedStart = NSDate()
        
        setupCaptureSession()
    }
    
    
    
    
    
    override func viewDidDisappear(animated: Bool){
        
        super.viewDidDisappear(animated)
        stop()
    }
    

    

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }


}

