import Cocoa
import Quartz
import SwiftUI

class PreviewViewController: NSViewController, QLPreviewingController {
    
    private var audioModel: AudioModel?
    
    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        self.view = NSView()
        self.view.autoresizingMask = [.width, .height]
    }
    
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Create the AudioModel and load the file
        let model = AudioModel()
        self.audioModel = model
        
        // Create the SwiftUI view
        let spectrumView = SpectrumView(audioModel: model)
        
        // Host it in an NSHostingView
        let hostingView = NSHostingView(rootView: spectrumView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: self.view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        
        // Load file (this generates the static spectrogram)
        model.loadFile(url: url)
        
        handler(nil)
    }
}
