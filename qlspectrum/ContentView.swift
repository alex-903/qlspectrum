//
//  ContentView.swift
//  qlspectrum
//
//  Created by Alex Krysiuk on 12/14/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var audioModel = AudioModel()
    @State private var isImporting = false
    
    var body: some View {
        VStack {
            SpectrumView(audioModel: audioModel)
                .frame(minWidth: 600, minHeight: 300)
            
            HStack(spacing: 12) {
                Button("Open Audio File") {
                    isImporting = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                
                if let fileName = audioModel.fileName {
                    Text(fileName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.audio],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let selectedFile: URL = try result.get().first else { return }
                // AudioModel handles security scoping internally
                audioModel.loadFile(url: selectedFile)
            } catch {
                print("Error importing file: \(error)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        audioModel.loadFile(url: url)
                    }
                } else if let url = item as? URL {
                    DispatchQueue.main.async {
                        audioModel.loadFile(url: url)
                    }
                }
            }
            return true
        }
    }
}

#Preview {
    ContentView()
}
