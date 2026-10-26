// CallScreenView - Full screen call interface with WebRTC
import SwiftUI
import AVKit

struct CallScreenView: View {
    let callInfo: AppState.ActiveCallInfo
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: CallViewModel
    @State private var showingEndCallAlert = false
    
    init(callInfo: AppState.ActiveCallInfo) {
        self.callInfo = callInfo
        self._viewModel = StateObject(wrappedValue: CallViewModel(callInfo: callInfo))
    }
    
    var body: some View {
        ZStack {
            Color(.black)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top bar
                CallTopBarView(showingEndCallAlert: $showingEndCallAlert)
                
                Spacer()
                
                // Video area
                if callInfo.type == .VIDEO {
                    VideoCallView(viewModel: viewModel)
                } else {
                    VoiceCallView(viewModel: viewModel)
                }
                
                Spacer()
                
                // Bottom bar
                CallBottomBarView(
                    isMuted: viewModel.isMuted,
                    onEndCall: { await viewModel.endCall() },
    onMuteToggle: { await viewModel.toggleMute() },
                    onSpeakerToggle: { /* TODO */ }
                )
            }
        }
        .navigationBarBackButtonHidden(true)
        .alert("End Call", isPresented: $showingEndCallAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) { }
        } message: {
            Text("Are you sure you want to end the call?")
        }
    }
}

// MARK: - Call ViewModel

@MainActor
final class CallViewModel: ObservableObject {
    let callInfo: AppState.ActiveCallInfo
    
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var callDuration: TimeInterval = 0
    @Published var isConnected = false
    
    private var startDate: Date?
    private var timer: Timer?
    
    init(callInfo: AppState.ActiveCallInfo) {
        self.callInfo = callInfo
        startDate = Date()
        startTimer()
        
        // TODO: Initialize WebRTC peer connection
        // This would use Socket.IO signaling + WebRTC
        // For now, simulate connection
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            // Simulate connection established after signaling
            Task { @MainActor in
                self.isConnected = true
            }
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startDate else { return }
            self.callDuration = Date().timeIntervalSince(start)
        }
    }
    
    func toggleMute() async {
        isMuted.toggle()
        // TODO: Send mute signal via WebRTC
        await socketEmit("call:mute", ["muted": isMuted])
    }
    
    func endCall() async {
        timer?.invalidate()
        timer = nil
        
        // TODO: Send hangup signal via WebRTC
        await socketEmit("call:end", ["callId": callInfo.callId])
        
        // Return to chats
        appState.endActiveCall()
    }
    
    private func socketEmit(_ event: String, _ data: [String: Any]) {
        // TODO: Implement actual socket emit
        print("Socket emit: \(event) \(data)")
    }
}

// MARK: - Supporting Views

struct CallTopBarView: View {
    @Binding var showingEndCallAlert: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingEndCallAlert = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // Call info
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Calling...")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(callInfo.otherUser.displayName)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                // Duration
                Text(formatDuration(Int(callDuration)))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            
            Divider()
                .background(Color.white.opacity(0.2))
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct VideoCallView: View {
    @ObservedObject var viewModel: CallViewModel
    @StateObject private var videoViewModel = VideoViewModel()
    
    var body: some View {
        ZStack {
            // Remote video
            VideoPreviewView(viewModel: videoViewModel, isLocal: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Local video (picture-in-picture)
            if videoViewModel.isLocalVideoAvailable {
                VideoPreviewView(viewModel: videoViewModel, isLocal: true)
                    .frame(width: 120, height: 120)
                    .padding(8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(20)
                    .offset(x: 100, y: -100)
            }
        }
    }
}

struct VoiceCallView: View {
    @ObservedObject var viewModel: CallViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            // Remote audio indicator
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calling...")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(viewModel.callInfo.otherUser.displayName)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
            }
            .padding(.horizontal, 20)
            
            Spacer()
            
            // Duration
            Text(formatDuration(Int(viewModel.callDuration)))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return mins > 0 ? String(format: "%d:%02d", mins, secs) : "0:\(String(format: "%02d", secs))"
    }
}

struct VideoPreviewView: View {
    @ObservedObject var viewModel: VideoViewModel
    let isLocal: Bool
    
    var body: some View {
        Group {
            if let previewImage = viewModel.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if viewModel.isCameraAccessEnabled {
                // Camera preview placeholder
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Image(systemName: isLocal ? "camera.viewfinder" : "person.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.5))
                    )
            } else {
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Text("Camera\nUnavailable")
                            .font(.caption)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task {
                await viewModel.setupCamera(isLocal: isLocal)
            }
        }
    }
}

class VideoViewModel: ObservableObject {
    @Published var previewImage: UIImage?
    @Published var isCameraAccessEnabled = false
    @Published var isLocal = false
    
    func setupCamera(isLocal: Bool) async {
        self.isLocal = isLocal
        // TODO: Set up AVCaptureSession for camera preview
        // For now, simulate
        try? await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run {
            self.isCameraAccessEnabled = true
            self.previewImage = UIImage(systemName: "circle.dotted")?.withRenderingMode(.alwaysTemplate)
        }
    }
}

struct CallBottomBarView: View {
    let isMuted: Bool
    let isSpeakerOn: Bool
    let onEndCall: () async -> Void
    let onMuteToggle: () async -> Void
    let onSpeakerToggle: () async -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                // Mute button
                CallControlButton(
                    icon: isMuted ? "mic.slash.fill" : "mic.fill",
                    title: "Mute",
                    color: isMuted ? .gray : .blue,
                    action: onMuteToggle
                )
                
                // Speaker button
                CallControlButton(
                    icon: isSpeakerOn ? "speaker.fill" : "speaker.slash.fill",
                    title: "Speaker",
                    color: .green,
                    action: onSpeakerToggle
                )
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // End call button
            Button {
                Task { await onEndCall() }
            } label: {
                HStack {
                    Image(systemName: "phone.down.fill")
                    Text("End Call")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.red)
                .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .background(Color.black)
    }
}

struct CallControlButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () async -> Void
    
    var body: some View {
        Button(action: { Task { await action() } }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(color)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CallScreenView(callInfo: AppState.ActiveCallInfo(
        callId: "test-call-123",
        conversationId: "test-conv-456",
        otherUser: User(
            id: "2",
            phoneNumber: "+1 (555) 987-6543",
            name: "Jane Doe",
            avatarUrl: nil,
            bio: nil,
            isOnline: false,
            lastSeen: nil,
            createdAt: nil
        ),
        type: .VIDEO,
        isOutgoing: true
    ))
    .environmentObject(AppState.shared)
}