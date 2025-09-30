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
    @Published var playDuration = 0.0
    
    let player = AudioPlayer()
    let engine = AudioEngine()
    let initialDevice: Device
    let session = AVAudioSession.sharedInstance()
    let mic: AudioEngine.InputNode
    let tappableNodeA: Fader
    let tappableNodeB: Fader
    let tappableNodeC: Fader
    let silence: Fader
    let mixer: Mixer //믹서 추가
    var tracker: PitchTap!
    
    let noteFrequencies = [16.35, 17.32, 18.35, 19.45, 20.6, 21.83, 23.12, 24.5, 25.96, 27.5, 29.14, 30.87]
    let noteNamesWithSharps = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    let noteNamesWithFlats = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
    
    // 피치 범위 설정 (시각화를 위한)
    let minPitch: Float = 80.0   // 낮은 음역
    let maxPitch: Float = 800.0  // 높은 음역
    private var updateTimer: Timer?
    init() {
        do {
            try session.setCategory(
                .playAndRecord,              // 송수신 모두
                mode: .voiceChat,           // 에코 캔슬레이션
                options: [
                    .allowBluetooth,         // 블루투스 헤드셋
                    .defaultToSpeaker       // 스피커 기본
                ]
            )
            try session.setActive(true)
        } catch {
            print("통화 앱 세션 설정 오류: \(error)")
        }
        
        guard let input = engine.input else { fatalError() }
        guard let device = engine.inputDevice else { fatalError() }
        guard let song = URL(string: "https://zwwoqjumejiouapcoxix.supabase.co/storage/v1/object/sign/songs/melody/0095b3fd-1f22-4e07-8544-077b257ffabb.mp3?token=eyJraWQiOiJzdG9yYWdlLXVybC1zaWduaW5nLWtleV8yYTE3NjQ5Yy01MWU0LTQzNzItYjMyYi0yNzkxOGI2NDg4YjIiLCJhbGciOiJIUzI1NiJ9. .jRucGLSvR6UuUkPsZWigCjiVM2uJVAFif_WStCQfft4") else {fatalError()}
        initialDevice = device
        mic = input
        tappableNodeA = Fader(mic)
        tappableNodeB = Fader(tappableNodeA)
        tappableNodeC = Fader(tappableNodeB)
        silence = Fader(tappableNodeC, gain: 0)
        mixer = Mixer(player)
        engine.output = mixer
        tracker = PitchTap(mic) { pitch, amp in
            DispatchQueue.main.async {
                self.update(pitch[0], amp[0])
            }
        }
        do{
            try engine.start()}
        catch {
            print("오디오 엔진 시작 오류: \(error)")
            return
        }
        tracker.start()
        func playSong() {
            do {
                try? player.load(url: song)
                player.play()
            }
        }
        player.completionHandler = playSong
        // 궤적 업데이트를 위한 타이머
        startTrailUpdateTimer()
    }
    
    private func startTrailUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            DispatchQueue.main.async {
                self.updateTrail()
            }
        }
    }
    
    func update(_ pitch: AUValue, _ amp: AUValue) {
        // 배경 소음에 대한 민감도 감소
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
        
        // 3초 이상 된 포인트들 제거
        pitchHistory.removeAll { currentTime.timeIntervalSince($0.timestamp) > 3.0 }
        
        // 유효한 피치가 있을 때만 궤적에 추가
        if data.amplitude > 0.1 && data.pitch > 0 {
            let normalizedY = CGFloat((data.pitch - minPitch) / (maxPitch - minPitch))
            let clampedY = max(0, min(1, normalizedY))
            
            let newPoint = PitchPoint(
                x: CGFloat(pitchHistory.count) * 2, // 간격 조정
                y: clampedY,
                timestamp: currentTime,
                opacity: 1.0
            )
            
            pitchHistory.append(newPoint)
            
            // 너무 많은 포인트가 쌓이지 않도록 제한
            if pitchHistory.count > 150 {
                pitchHistory.removeFirst()
            }
        }
    }
    
    deinit {
        updateTimer?.invalidate()
    }
}

struct PitchVisualizerView: View {
    @StateObject var conductor = AudioRecorderManager()
    @State private var spherePosition: CGFloat = 0.5
    @State private var animationOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            // 정보 표시 패널
            VStack {
                InfoPanel(conductor: conductor)
                    .padding()
            }
            ZStack {
                // 배경
                LinearGradient(
                    colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                // 궤적 그리기
                TrailView(pitchHistory: conductor.pitchHistory, geometry: geometry)
                
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

struct TrailView: View {
    let pitchHistory: [PitchPoint]
    let geometry: GeometryProxy
    
    var body: some View {
        Canvas { context, size in
            let currentTime = Date()
            
            for (index, point) in pitchHistory.enumerated() {
                let age = currentTime.timeIntervalSince(point.timestamp)
                let opacity = max(0, 1.0 - age / 3.0) // 3초에 걸쳐 페이드아웃
                
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
            
            // 궤적을 선으로 연결
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
            
            // 음량 인디케이터
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

// 메인 뷰
struct AudioLevelView: View {
    var body: some View {
        PitchVisualizerView()
    }
}
