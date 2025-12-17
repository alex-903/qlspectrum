import SwiftUI

struct SpectrumView: View {
    @ObservedObject var audioModel: AudioModel
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if let image = audioModel.spectrogramImage {
                    // Spectrogram Image
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if selectionStart == nil {
                                        selectionStart = value.startLocation
                                    }
                                    selectionEnd = value.location
                                }
                                .onEnded { value in
                                    let start = selectionStart ?? value.startLocation
                                    let end = value.location
                                    
                                    // Only zoom if selection is large enough (avoid accidental clicks)
                                    if abs(end.x - start.x) > 10 || abs(end.y - start.y) > 10 {
                                        processSelection(start: start, end: end, size: geometry.size)
                                    } else {
                                        // Click to reset zoom
                                        if audioModel.isZoomed {
                                            audioModel.resetZoom()
                                        }
                                    }
                                    
                                    selectionStart = nil
                                    selectionEnd = nil
                                }
                        )
                    
                    // Axes
                    AxesView(audioModel: audioModel, size: geometry.size)
                        .allowsHitTesting(false)
                    
                    // Selection Overlay
                    if let start = selectionStart, let end = selectionEnd {
                        SelectionRect(start: start, end: end)
                    }
                } else if audioModel.isLoading {
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                            .scaleEffect(1.5)
                        Text("Generating spectrogram...")
                            .font(.headline)
                            .foregroundColor(.cyan)
                            .padding(.top)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let error = audioModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                            .padding()
                        Text("Drag and drop an audio file here")
                            .foregroundColor(.gray)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
    
    private func processSelection(start: CGPoint, end: CGPoint, size: CGSize) {
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        
        // Current Ranges
        let currentStartTime = audioModel.visibleTimeRange?.lowerBound ?? 0
        let currentEndTime = audioModel.visibleTimeRange?.upperBound ?? audioModel.duration
        let currentDuration = currentEndTime - currentStartTime
        
        let currentMinFreq = audioModel.visibleFrequencyRange?.lowerBound ?? 0
        let currentMaxFreq = audioModel.visibleFrequencyRange?.upperBound ?? (audioModel.sampleRate / 2)
        let currentFreqRange = currentMaxFreq - currentMinFreq
        
        // Map X to Time
        let newStartTime = currentStartTime + (Double(minX) / Double(size.width)) * currentDuration
        let newEndTime = currentStartTime + (Double(maxX) / Double(size.width)) * currentDuration
        
        // Map Y to Frequency
        // Y=0 is Max Freq, Y=Height is Min Freq
        // Normalized Y (0 top, 1 bottom)
        let normMinY = Double(minY) / Double(size.height)
        let normMaxY = Double(maxY) / Double(size.height)
        
        // Freq = MinFreq + (1 - NormY) * Range
        let newMaxFreq = currentMinFreq + (1.0 - normMinY) * currentFreqRange
        let newMinFreq = currentMinFreq + (1.0 - normMaxY) * currentFreqRange
        
        audioModel.zoom(
            timeRange: newStartTime...newEndTime,
            frequencyRange: newMinFreq...newMaxFreq
        )
    }
}

struct SelectionRect: View {
    let start: CGPoint
    let end: CGPoint
    
    var body: some View {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        
        Rectangle()
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5]))
            .background(Color.white.opacity(0.2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

struct AxesView: View {
    @ObservedObject var audioModel: AudioModel
    let size: CGSize
    
    var body: some View {
        ZStack {
            // Time Axis (Bottom)
            VStack {
                Spacer()
                HStack {
                    let start = audioModel.visibleTimeRange?.lowerBound ?? 0
                    let end = audioModel.visibleTimeRange?.upperBound ?? audioModel.duration
                    
                    Text(formatTime(start))
                    Spacer()
                    Text(formatTime((start + end) / 2))
                    Spacer()
                    Text(formatTime(end))
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.leading, 60) // Avoid overlap with frequency axis
                .background(Color.black)
            }
            
            // Frequency Axis (Left)
            HStack {
                VStack(alignment: .leading) {
                    let minF = audioModel.visibleFrequencyRange?.lowerBound ?? 0
                    let maxF = audioModel.visibleFrequencyRange?.upperBound ?? (audioModel.sampleRate / 2)
                    
                    Text(formatFreq(maxF))
                    Spacer()
                    Text(formatFreq((minF + maxF) / 2))
                    Spacer()
                    Text(formatFreq(minF))
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.vertical, 4)
                .background(Color.black)
                
                Spacer()
            }
        }
    }
    
    func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, ms)
    }
    
    func formatFreq(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1fkHz", hz / 1000)
        } else {
            return String(format: "%.0fHz", hz)
        }
    }
}
