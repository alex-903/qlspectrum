import SwiftUI
import AVFoundation
import Accelerate
import Combine
import AppKit

struct SpectrogramResult {
    let image: NSImage
    let duration: TimeInterval
    let sampleRate: Double
    let timeRange: ClosedRange<Double>
    let frequencyRange: ClosedRange<Double>
}

// Static spectrogram generator - reads entire file and creates an image
class SpectrogramGenerator {
    
    static func generateSpectrogram(
        from url: URL,
        width: Int = 800,
        height: Int = 400,
        timeRange: ClosedRange<Double>? = nil,
        frequencyRange: ClosedRange<Double>? = nil
    ) -> SpectrogramResult? {
        print("Generating spectrogram for: \(url.path)")
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let totalFrames = audioFile.length
            let sampleRate = format.sampleRate
            let duration = Double(totalFrames) / sampleRate
            
            // Determine time range to process
            let startTime = timeRange?.lowerBound ?? 0
            let endTime = timeRange?.upperBound ?? duration
            
            let startFrame = AVAudioFramePosition(startTime * sampleRate)
            let endFrame = AVAudioFramePosition(endTime * sampleRate)
            let framesToRead = AVAudioFrameCount(max(0, min(totalFrames - startFrame, endFrame - startFrame)))
            
            guard framesToRead > 0 else { return nil }
            
            audioFile.framePosition = startFrame
            
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                print("Failed to create buffer")
                return nil
            }
            
            try audioFile.read(into: buffer)
            
            guard let channelData = buffer.floatChannelData?[0] else {
                print("No float channel data")
                return nil
            }
            
            let samplesRead = Int(buffer.frameLength)
            
            // FFT parameters
            let fftSize = 2048
            let hopSize = fftSize / 4
            let numFrames = max(1, (samplesRead - fftSize) / hopSize)
            let numBins = fftSize / 2
            
            // Setup FFT
            guard let fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
                print("Failed to create FFT setup")
                return nil
            }
            defer { vDSP_DFT_DestroySetup(fftSetup) }
            
            // Create Hanning window
            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            
            // Compute spectrogram
            // Optimization: Use flat array to avoid overhead and improve cache locality
            var spectrogram = [Float](repeating: 0, count: numFrames * numBins)
            
            spectrogram.withUnsafeMutableBufferPointer { spectrogramBuf in
                guard let spectrogramPtr = spectrogramBuf.baseAddress else { return }
                
                // Optimization: Reuse FFT buffers to avoid per-frame allocations
                var real = [Float](repeating: 0, count: fftSize)
                var imag = [Float](repeating: 0, count: fftSize)
                var realOut = [Float](repeating: 0, count: fftSize)
                var imagOut = [Float](repeating: 0, count: fftSize)
                
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    if let imagPtr = imagBuf.baseAddress {
                        vDSP_vclr(imagPtr, 1, vDSP_Length(fftSize))
                    }
                }
                
                for frame in 0..<numFrames {
                    let startSample = frame * hopSize
                    
                    // Extract frame and apply window into reusable FFT input buffer
                    if startSample + fftSize <= samplesRead {
                        // Fast path: full frame available, use vectorized multiply
                        real.withUnsafeMutableBufferPointer { realBuf in
                            window.withUnsafeBufferPointer { windowBuf in
                                guard let realPtr = realBuf.baseAddress, let windowPtr = windowBuf.baseAddress else { return }
                                vDSP_vmul(channelData.advanced(by: startSample), 1, windowPtr, 1, realPtr, 1, vDSP_Length(fftSize))
                            }
                        }
                    } else {
                        // Tail path: partial frame, zero-pad
                        for i in 0..<fftSize {
                            let sampleIndex = startSample + i
                            if sampleIndex < samplesRead {
                                real[i] = channelData[sampleIndex] * window[i]
                            } else {
                                real[i] = 0
                            }
                        }
                    }
                    
                    vDSP_DFT_Execute(fftSetup, &real, &imag, &realOut, &imagOut)
                    
                    // Compute magnitudes directly into the output buffer
                    let frameOffset = frame * numBins
                    var magnitudesPtr = spectrogramPtr + frameOffset
                    
                    realOut.withUnsafeMutableBufferPointer { realBuf in
                        imagOut.withUnsafeMutableBufferPointer { imagBuf in
                            guard let realPtr = realBuf.baseAddress, let imagPtr = imagBuf.baseAddress else { return }
                            var complex = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                            vDSP_zvabs(&complex, 1, magnitudesPtr, 1, vDSP_Length(numBins))
                        }
                    }
                    
                    // Convert to dB scale in place
                    var one: Float = 1.0
                    vDSP_vdbcon(magnitudesPtr, 1, &one, magnitudesPtr, 1, vDSP_Length(numBins), 0)
                }
            }
            
            // Determine frequency range to render
            let nyquist = sampleRate / 2.0
            let minFreq = frequencyRange?.lowerBound ?? 0
            let maxFreq = frequencyRange?.upperBound ?? nyquist
            
            // Render to image
            guard let image = renderSpectrogram(
                spectrogram,
                numFrames: numFrames,
                numBins: numBins,
                width: width,
                height: height,
                nyquist: nyquist,
                minFreq: minFreq,
                maxFreq: maxFreq
            ) else { return nil }
            
            return SpectrogramResult(
                image: image,
                duration: duration,
                sampleRate: sampleRate,
                timeRange: startTime...endTime,
                frequencyRange: minFreq...maxFreq
            )
            
        } catch {
            print("Error generating spectrogram: \(error)")
            return nil
        }
    }
    
    private static func renderSpectrogram(
        _ spectrogram: [Float],
        numFrames: Int,
        numBins: Int,
        width: Int,
        height: Int,
        nyquist: Double,
        minFreq: Double,
        maxFreq: Double
    ) -> NSImage? {
        guard numFrames > 0 && numBins > 0 else { return nil }
        
        // Calculate bin range
        let binWidth = nyquist / Double(numBins)
        let minBin = Int(minFreq / binWidth)
        let maxBin = min(Int(maxFreq / binWidth), numBins - 1)
        let renderBinCount = max(1, maxBin - minBin + 1)
        
        // Find min/max for normalization (only within the visible range)
        var minVal: Float = 0
        var maxVal: Float = -Float.infinity
        
        // Optimization: Sample a subset of frames to find min/max if too large
        let step = max(1, numFrames / 100)
        for i in stride(from: 0, to: numFrames, by: step) {
            let frameOffset = i * numBins
            for bin in minBin...maxBin {
                let val = spectrogram[frameOffset + bin]
                if val.isFinite {
                    if val > maxVal { maxVal = val }
                    if val < minVal { minVal = val }
                }
            }
        }
        
        // Clamp range
        minVal = max(minVal, -100) // -100 dB floor
        maxVal = min(maxVal, 0)    // 0 dB ceiling
        let range = maxVal - minVal
        
        // Create bitmap
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        
        // Precompute LUT
        let colorLUT = (0...255).map { i -> (UInt8, UInt8, UInt8) in
            return spectrogramColor(Float(i) / 255.0)
        }
        
        pixelData.withUnsafeMutableBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            
            // Parallelize row processing
            DispatchQueue.concurrentPerform(iterations: height) { y in
                // Map Y to frequency bin
                let normalizedY = Double(y) / Double(height) // 0 at bottom, 1 at top
                let binIndex = minBin + Int(normalizedY * Double(renderBinCount))
                let safeBinIndex = min(max(minBin, binIndex), maxBin)
                
                // Pre-calculate row offset
                // Flip Y for image coordinate system (0 at top)
                let imageY = height - 1 - y
                let rowOffset = imageY * width * bytesPerPixel
                
                for x in 0..<width {
                    let frameIndex = x * numFrames / width
                    let dataIndex = frameIndex * numBins + safeBinIndex
                    
                    var value = spectrogram[dataIndex]
                    if !value.isFinite { value = minVal }
                    
                    // Normalize to 0-1
                    let normalized = (value - minVal) / range
                    let clamped = max(0, min(1, normalized))
                    
                    // Color mapping via LUT
                    let lutIndex = Int(clamped * 255.0)
                    let (r, g, b) = colorLUT[lutIndex]
                    
                    let offset = rowOffset + x * bytesPerPixel
                    
                    baseAddress[offset] = r
                    baseAddress[offset + 1] = g
                    baseAddress[offset + 2] = b
                    baseAddress[offset + 3] = 255
                }
            }
        }
        
        // Create CGImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        guard let cgImage = context.makeImage() else { return nil }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
    
    private static func spectrogramColor(_ value: Float) -> (UInt8, UInt8, UInt8) {
        // Tidal-like scheme: Black -> Dark Blue -> Cyan -> Near-White Yellow
        let v = value

        let r: Float
        let g: Float
        let b: Float

        if v < 0.05 {
            // Black (Silence)
            r = 0; g = 0; b = 0
        } else if v < 0.33 {
            // Black to Dark Blue
            let t = (v - 0.05) / 0.28
            r = 0
            g = t * 0.1
            b = t * 0.5
        } else if v < 0.66 {
            // Dark Blue to Cyan
            let t = (v - 0.33) / 0.33
            r = 0
            g = 0.1 + t * 0.8
            b = 0.5 + t * 0.5
        } else {
            // Cyan to Near-White Yellow
            let t = (v - 0.66) / 0.34
            r = t
            g = 0.9 + t * 0.1
            b = 1.0 - t * 0.5 // Ends at 0.5 for a distinct yellow
        }

        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
}

// Simple view model for the static image
class AudioModel: ObservableObject {
    @Published var spectrogramImage: NSImage?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // Metadata
    @Published var duration: TimeInterval = 0
    @Published var sampleRate: Double = 44100
    @Published var visibleTimeRange: ClosedRange<Double>?
    @Published var visibleFrequencyRange: ClosedRange<Double>?
    @Published var fileName: String?
    
    // Cached full view for instant reset
    private var cachedFullImage: NSImage?
    private var cachedFullTimeRange: ClosedRange<Double>?
    private var cachedFullFrequencyRange: ClosedRange<Double>?
    
    var isZoomed: Bool {
        guard let visibleTime = visibleTimeRange, let visibleFreq = visibleFrequencyRange else { return false }
        let timeZoomed = (visibleTime.upperBound - visibleTime.lowerBound) < (duration * 0.99)
        let freqZoomed = (visibleFreq.upperBound - visibleFreq.lowerBound) < ((sampleRate / 2) * 0.99)
        return timeZoomed || freqZoomed
    }
    
    private var currentUrl: URL?
    
    func loadFile(url: URL) {
        // Explicitly release old images to free memory
        self.spectrogramImage = nil
        self.cachedFullImage = nil
        self.cachedFullTimeRange = nil
        self.cachedFullFrequencyRange = nil
        
        self.currentUrl = url
        self.fileName = url.lastPathComponent
        self.visibleTimeRange = nil
        self.visibleFrequencyRange = nil
        self.duration = 0
        
        generate(url: url, cacheAsFullView: true)
    }
    
    func zoom(timeRange: ClosedRange<Double>, frequencyRange: ClosedRange<Double>) {
        guard let url = currentUrl else { return }
        generate(url: url, timeRange: timeRange, frequencyRange: frequencyRange, cacheAsFullView: false)
    }
    
    func resetZoom() {
        // Use cached image for instant reset
        if let cached = cachedFullImage {
            self.spectrogramImage = cached
            self.visibleTimeRange = cachedFullTimeRange
            self.visibleFrequencyRange = cachedFullFrequencyRange
            return
        }
        
        // Fallback to regenerating if no cache
        guard let url = currentUrl else { return }
        self.visibleTimeRange = nil
        self.visibleFrequencyRange = nil
        generate(url: url, cacheAsFullView: true)
    }
    
    private func generate(url: URL, timeRange: ClosedRange<Double>? = nil, frequencyRange: ClosedRange<Double>? = nil, cacheAsFullView: Bool = false) {
        self.isLoading = true
        self.errorMessage = nil
        
        // Clear old zoom images when loading a new file at full view
        if cacheAsFullView {
            self.spectrogramImage = nil
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Ensure we can access the file (needed for Sandboxed apps and Quick Look)
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            let result = SpectrogramGenerator.generateSpectrogram(
                from: url,
                width: 1200,
                height: 600,
                timeRange: timeRange,
                frequencyRange: frequencyRange
            )
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.isLoading = false
                if let result = result {
                    // Release old image before assigning new one
                    if cacheAsFullView {
                        self.cachedFullImage = nil
                    }
                    
                    self.spectrogramImage = result.image
                    self.duration = result.duration
                    self.sampleRate = result.sampleRate
                    self.visibleTimeRange = result.timeRange
                    self.visibleFrequencyRange = result.frequencyRange
                    
                    // Cache the full view for instant reset
                    if cacheAsFullView {
                        self.cachedFullImage = result.image
                        self.cachedFullTimeRange = result.timeRange
                        self.cachedFullFrequencyRange = result.frequencyRange
                    }
                } else {
                    self.errorMessage = "Could not generate spectrogram"
                }
            }
        }
    }
}
