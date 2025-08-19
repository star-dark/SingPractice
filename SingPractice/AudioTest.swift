//
//  AudioTest.swift
//  SingPractice
//
//  Created by KimDaeHyeung on 8/17/25.
//
import SwiftUI
import AVFoundation
import Speech

func setupAudioSession() {
    do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    } catch {
        fatalError("Failed to configure and activate session.")
    }
}
struct VoiceRecorderView: View {
    var body: some View {
        Text("Hello, World!")
        Button("Start Recording") {
            setupAudioSession()
        }
    }
}

// MARK: - App Entry Point
struct VoiceRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            VoiceRecorderView()
        }
    }
}

// MARK: - Preview
struct VoiceRecorderView_Previews: PreviewProvider {
    static var previews: some View {
        VoiceRecorderView()
    }
}
