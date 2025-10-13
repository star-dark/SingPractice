import SwiftUI
import AVFoundation
import AudioKit
import AudioKitEX
import AudioKitUI
import AudioToolbox
import SoundpipeAudioKit

struct TunerData {
    var pitch: Float = 0.0
    var amplitude: Float = 0.0
    var noteNameWithSharps = "-"
    var noteNameWithFlats = "-"
}

struct PitchPoint {
    let x: CGFloat
    let y: CGFloat
    let timestamp: Date
    let opacity: Double
}

class AudioRecorderManager: ObservableObject, HasAudioEngine {
    @Published var data = TunerData()
    @Published var pitchHistory: [PitchPoint] = []
    @Published var isPlaying = false
    
    let engine = AudioEngine()
    let initialDevice: Device
    let mic: AudioEngine.InputNode
    let tappableNodeA: Fader
    let tappableNodeB: Fader
    let tappableNodeC: Fader
    let silence: Fader
    var tracker: PitchTap!
    
    // AudioKit Player 추가
    var player: AudioPlayer?
    var playerFader: Fader?
    var mixer: Mixer?
    
    // AVAudioPlayer로 폴백
    var avPlayer: AVAudioPlayer?
    
    let noteFrequencies = [16.35, 17.32, 18.35, 19.45, 20.6, 21.83, 23.12, 24.5, 25.96, 27.5, 29.14, 30.87]
    let noteNamesWithSharps = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    let noteNamesWithFlats = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
    
    let minPitch: Float = 80.0
    let maxPitch: Float = 800.0
    private var updateTimer: Timer?
    
    init() {
        // AudioKit 전용 오디오 세션 설정
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
                    .defaultToSpeaker,
                    .allowBluetooth,
                    .mixWithOthers
                ]
            )
            try session.setActive(true)
            print("✅ 오디오 세션 설정 완료")
        } catch {
            print("❌ 오디오 세션 설정 실패: \(error)")
        }
        #endif
        
        guard let input = engine.input else { fatalError("No input available") }
        guard let device = engine.inputDevice else { fatalError("No input device") }
        
        initialDevice = device
        mic = input
        tappableNodeA = Fader(mic)
        tappableNodeB = Fader(tappableNodeA)
        tappableNodeC = Fader(tappableNodeB)
        silence = Fader(tappableNodeC, gain: 0)
        
        // 노래 파일 로드 시도
        setupAudioPlayer()
        
        // PitchTap 설정
        tracker = PitchTap(mic) { pitch, amp in
            DispatchQueue.main.async {
                self.update(pitch[0], amp[0])
            }
        }
        
        tracker.start()
        startTrailUpdateTimer()
        
        // 🎵 init에서 자동으로 노래 재생 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.autoStartPlayback()
        }
    }
    
    private func autoStartPlayback() {
        guard let player = player else {
            print("❌ 플레이어가 초기화되지 않았습니다")
            return
        }
        
        print("🎵 자동 재생 시작...")
        print("🔍 엔진 상태:")
        print("   - 엔진 실행 중: \(engine.avEngine.isRunning)")
        print("   - 플레이어 준비: \(player.isStarted)")
        
        // 엔진이 멈춰있으면 시작
        if !engine.avEngine.isRunning {
            print("🔄 AudioKit 엔진 시작 중...")
            do {
                try engine.start()
                print("✅ AudioKit 엔진 시작됨")
            } catch {
                print("❌ AudioKit 엔진 시작 실패: \(error)")
                return
            }
        }
        
        // 플레이어 시작
        player.play()
        isPlaying = true
        
        print("▶️ 자동 재생 완료")
        print("   - Volume: \(player.volume)")
        print("   - IsPlaying: \(player.isPlaying)")
        print("   - IsStarted: \(player.isStarted)")
        
        // 1초 후 상태 재확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("🔍 1초 후 재생 상태:")
            print("   - IsPlaying: \(player.isPlaying)")
            print("   - 엔진 실행 중: \(self.engine.avEngine.isRunning)")
            
            if !player.isPlaying {
                print("⚠️ 재생이 멈췄습니다. 다시 시도...")
                player.play()
            }
        }
    }
    
    private func setupAudioPlayer() {
        guard let songURL = Bundle.main.url(forResource: "vocals", withExtension: "wav") else {
            print("❌ vocals.wav 파일을 찾을 수 없습니다")
            print("📁 Bundle 경로: \(Bundle.main.bundlePath)")
            engine.output = silence
            return
        }
        
        print("✅ 파일 경로 확인: \(songURL.path)")
        
        do {
            let audioFile = try AVAudioFile(forReading: songURL)
            player = AudioPlayer(file: audioFile)
            player?.volume = 1.0
            player?.isLooping = false
            
            // 중요: Fader로 볼륨 조절 가능하게
            playerFader = Fader(player!, gain: 1.0)
            
            // Mixer로 플레이어와 마이크(silence) 믹싱
            mixer = Mixer(playerFader!, silence)
            engine.output = mixer
            
            print("✅ AudioKit Player로 파일 로드 성공")
            print("   샘플레이트: \(audioFile.fileFormat.sampleRate) Hz")
            print("   채널: \(audioFile.fileFormat.channelCount)")
            print("   길이: \(Double(audioFile.length) / audioFile.fileFormat.sampleRate) 초")
            
            // 🔥 중요: 엔진 시작
            do {
                try engine.start()
                print("✅ AudioKit 엔진 시작 완료")
            } catch {
                print("❌ AudioKit 엔진 시작 실패: \(error)")
            }
            
        } catch {
            print("⚠️ AudioKit Player 실패: \(error)")
            engine.output = silence
        }
    }
    
    func togglePlayback() {
        guard let player = player else {
            print("❌ 플레이어가 초기화되지 않았습니다")
            return
        }
        
        if player.isPlaying {
            player.pause()
            isPlaying = false
            print("⏸️ 재생 일시정지")
        } else {
            // 엔진 상태 확인
            print("🔍 엔진 상태:")
            print("   - 엔진 실행 중: \(engine.avEngine.isRunning)")
            print("   - 플레이어 준비: \(player.isStarted)")
            
            // 엔진이 멈춰있으면 재시작
            if !engine.avEngine.isRunning {
                print("🔄 AudioKit 엔진 재시작 중...")
                do {
                    try engine.start()
                    print("✅ AudioKit 엔진 시작됨")
                } catch {
                    print("❌ AudioKit 엔진 시작 실패: \(error)")
                    return
                }
            }
            
            // 플레이어 시작
            player.play()
            isPlaying = true
            
            print("▶️ 재생 시작")
            print("   - Volume: \(player.volume)")
            print("   - IsPlaying: \(player.isPlaying)")
            print("   - IsStarted: \(player.isStarted)")
            
            // 0.5초 후 상태 재확인
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("🔍 0.5초 후 상태:")
                print("   - IsPlaying: \(player.isPlaying)")
                print("   - 엔진 실행 중: \(self.engine.avEngine.isRunning)")
            }
        }
    }
    
    func stopPlayback() {
        player?.stop()
        isPlaying = false
        print("⏹️ 재생 중지")
    }
    
    private func startTrailUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            DispatchQueue.main.async {
                self.updateTrail()
            }
        }
    }
    
    func update(_ pitch: AUValue, _ amp: AUValue) {
        guard amp > 0.1 else { return }

        data.pitch = pitch
        data.amplitude = amp

        var frequency = pitch
        while frequency > Float(noteFrequencies[noteFrequencies.count - 1]) {
            frequency /= 2.0
        }
        while frequency < Float(noteFrequencies[0]) {
            frequency *= 2.0
        }

        var minDistance: Float = 10000.0
        var index = 0

        for possibleIndex in 0 ..< noteFrequencies.count {
            let distance = fabsf(Float(noteFrequencies[possibleIndex]) - frequency)
            if distance < minDistance {
                index = possibleIndex
                minDistance = distance
            }
        }
        let octave = Int(log2f(pitch / frequency))
        data.noteNameWithSharps = "\(noteNamesWithSharps[index])\(octave)"
        data.noteNameWithFlats = "\(noteNamesWithFlats[index])\(octave)"
    }
    
    private func updateTrail() {
        let currentTime = Date()
        
        pitchHistory.removeAll { currentTime.timeIntervalSince($0.timestamp) > 3.0 }
        
        if data.amplitude > 0.1 && data.pitch > 0 {
            let normalizedY = CGFloat((data.pitch - minPitch) / (maxPitch - minPitch))
            let clampedY = max(0, min(1, normalizedY))
            
            let newPoint = PitchPoint(
                x: CGFloat(pitchHistory.count) * 2,
                y: clampedY,
                timestamp: currentTime,
                opacity: 1.0
            )
            
            pitchHistory.append(newPoint)
            
            if pitchHistory.count > 150 {
                pitchHistory.removeFirst()
            }
        }
    }
    
    deinit {
        updateTimer?.invalidate()
        tracker.stop()
        player?.stop()
        engine.stop()
    }
}

struct PitchVisualizerView: View {
    @StateObject var conductor = AudioRecorderManager()
    @State private var spherePosition: CGFloat = 0.5
    @State private var animationOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 배경
                LinearGradient(
                    colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack {
                    // 정보 표시 패널
                    InfoPanel(conductor: conductor)
                        .padding()
                    
                    Spacer()
                    
                    // 재생 컨트롤
                    PlaybackControls(conductor: conductor)
                        .padding()
                }
                
                // 궤적 그리기
                TrailView(pitchHistory: conductor.pitchHistory, geometry: geometry).allowsHitTesting(false)
                
                // 움직이는 구체
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, Color.blue.opacity(0.8)],
                            center: .center,
                            startRadius: 5,
                            endRadius: 25
                        )
                    )
                    .frame(width: 50, height: 50)
                    .shadow(color: .blue.opacity(0.5), radius: 10)
                    .position(
                        x: geometry.size.width - 250 + animationOffset,
                        y: geometry.size.height * (1 - spherePosition)
                    )
                    .animation(
                        .easeInOut(duration: 0.1),
                        value: spherePosition
                    )
                    .allowsHitTesting(false)
            }
        }
        .onReceive(conductor.$data) { data in
            updateSpherePosition(data: data)
        }
        .onAppear {
            conductor.start()
            startFloatingAnimation()
        }
        .onDisappear {
            conductor.stop()
        }
    }
    
    private func updateSpherePosition(data: TunerData) {
        guard data.amplitude > 0.1 && data.pitch > 0 else { return }
        
        let normalizedPitch = (data.pitch - conductor.minPitch) / (conductor.maxPitch - conductor.minPitch)
        let clampedPitch = max(0, min(1, normalizedPitch))
        
        spherePosition = CGFloat(clampedPitch)
    }
    
    private func startFloatingAnimation() {
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            animationOffset = 20
        }
    }
}

struct PlaybackControls: View {
    @ObservedObject var conductor: AudioRecorderManager
    
    var body: some View {
        HStack(spacing: 30) {
            Button(action: {
                print("🔘 정지 버튼 클릭됨")
                conductor.stopPlayback()
            }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
                    .shadow(radius: 5)
            }
            .buttonStyle(PlainButtonStyle()) // 버튼 스타일 명시
            
            Button(action: {
                print("🔘 재생/일시정지 버튼 클릭됨")
                conductor.togglePlayback()
            }) {
                Image(systemName: conductor.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .frame(width: 80, height: 80)
                    .background(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .shadow(radius: 10)
            }
            .buttonStyle(PlainButtonStyle()) // 버튼 스타일 명시
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(radius: 10)
        )
    }
}

struct TrailView: View {
    let pitchHistory: [PitchPoint]
    let geometry: GeometryProxy
    
    var body: some View {
        Canvas { context, size in
            let currentTime = Date()
            
            for (index, point) in pitchHistory.enumerated() {
                let age = currentTime.timeIntervalSince(point.timestamp)
                let opacity = max(0, 1.0 - age / 3.0)
                
                if opacity > 0 {
                    let x = size.width - CGFloat(pitchHistory.count - index) * 3 - 250
                    let y = size.height * (1 - point.y)
                    
                    let color = Color.blue.opacity(opacity * 0.6)
                    let radius = 3.0 + (opacity * 2.0)
                    
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: x - radius/2,
                            y: y - radius/2,
                            width: radius,
                            height: radius
                        )),
                        with: .color(color)
                    )
                }
            }
            
            if pitchHistory.count > 1 {
                var path = Path()
                let firstPoint = pitchHistory[0]
                let firstX = size.width - CGFloat(pitchHistory.count) * 3 - 250
                let firstY = size.height * (1 - firstPoint.y)
                path.move(to: CGPoint(x: firstX, y: firstY))
                
                for (index, point) in pitchHistory.enumerated().dropFirst() {
                    let x = size.width - CGFloat(pitchHistory.count - index) * 3 - 250
                    let y = size.height * (1 - point.y)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                context.stroke(path, with: .color(Color.blue.opacity(0.3)), lineWidth: 2)
            }
        }
    }
}

struct InfoPanel: View {
    @ObservedObject var conductor: AudioRecorderManager
    
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                VStack(alignment: .leading) {
                    Text("주파수")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(conductor.data.pitch, specifier: "%.1f") Hz")
                        .font(.title2)
                        .bold()
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("음계")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(conductor.data.noteNameWithSharps)")
                        .font(.title2)
                        .bold()
                }
            }
            
            VStack(alignment: .leading) {
                Text("음량")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [.green, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(
                            width: geometry.size.width * CGFloat(min(1.0, conductor.data.amplitude)),
                            height: 8
                        )
                }
                .frame(height: 8)
            }
            
            if conductor.isPlaying {
                HStack {
                    Image(systemName: "music.note")
                        .foregroundColor(.purple)
                    Text("재생 중")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }
            
            InputDevicePicker(device: conductor.initialDevice)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(.regularMaterial)
                .shadow(radius: 10)
        )
    }
}

struct InputDevicePicker: View {
    @State var device: Device

    var body: some View {
        Picker("입력: \(device.deviceID)", selection: $device) {
            ForEach(getDevices(), id: \.self) {
                Text($0.deviceID)
            }
        }
        .pickerStyle(MenuPickerStyle())
        .onChange(of: device, perform: setInputDevice)
    }

    func getDevices() -> [Device] {
        AudioEngine.inputDevices.compactMap { $0 }
    }

    func setInputDevice(to device: Device) {
        do {
            try AudioEngine.setInputDevice(device)
        } catch let err {
            print(err)
        }
    }
}

struct AudioLevelView: View {
    var body: some View {
        PitchVisualizerView()
    }
}
