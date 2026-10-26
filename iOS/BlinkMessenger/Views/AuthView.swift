// AuthView - Phone number authentication flow
import SwiftUI
import Combine

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = AuthViewModel()
    @FocusState private var focusedField: Field?
    
    enum Field {
        case phoneNumber, code
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header
                    headerView
                    
                    // Form
                    ScrollView {
                        VStack(spacing: 24) {
                            if viewModel.currentStep == .phoneNumber {
                                phoneNumberView
                            } else if viewModel.currentStep == .verification {
                                verificationView
                            } else if viewModel.currentStep == .profileSetup {
                                profileSetupView
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 40)
                    }
                    
                    Spacer()
                    
                    // Continue button
                    continueButton
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                }
            }
            .navigationBarHidden(true)
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { }
            } message: {
                Text(viewModel.errorMessage)
            }
            .onChange(of: viewModel.isAuthenticated) { _, authenticated in
                if authenticated {
                    Task {
                        await appState.initialize()
                    }
                }
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue.gradient)
            
            Text("Blink Messenger")
                .font(.largeTitle.bold())
            
            Text(viewModel.currentStep == .phoneNumber ? "Enter your phone number" : 
                 viewModel.currentStep == .verification ? "Enter verification code" : "Set up your profile")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.bottom, 20)
    }
    
    private var phoneNumberView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                // Country code picker (simplified)
                Menu {
                    ForEach(CountryCode.commonCodes, id: \.code) { country in
                        Button {
                            viewModel.selectedCountry = country
                        } label: {
                            HStack {
                                Text(country.flag)
                                Text(country.code)
                                if viewModel.selectedCountry.code == country.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(viewModel.selectedCountry.flag)
                            .font(.title2)
                        Text(viewModel.selectedCountry.code)
                            .font(.title3.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                
                // Phone number field
                TextField("Phone Number", text: $viewModel.phoneNumber)
                    .font(.title3)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phoneNumber)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .onChange(of: viewModel.phoneNumber) { _, newValue in
                        viewModel.phoneNumber = newValue.filter { "0123456789".contains($0) }
                    }
            }
            
            Text("We'll send an SMS with a verification code. Standard rates may apply.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var verificationView: some View {
        VStack(spacing: 24) {
            Text("Enter the 6-digit code sent to")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("\(viewModel.selectedCountry.code) \(viewModel.formattedPhoneNumber)")
                .font(.title3.weight(.medium))
            
            // Code input fields
            HStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { index in
                    CodeDigitField(
                        text: Binding(
                            get: { viewModel.codeDigits[index] },
                            set: { viewModel.codeDigits[index] = $0 }
                        ),
                        isFocused: focusedField == .code && viewModel.currentCodeIndex == index,
                        onTap: { focusedField = .code }
                    )
                }
            }
            
            // Resend timer
            if viewModel.canResendCode {
                Button("Resend Code") {
                    Task { await viewModel.sendCode() }
                }
                .font(.subheadline.weight(.medium))
            } else {
                Text("Resend code in \(viewModel.resendTimer)s")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var profileSetupView: some View {
        VStack(spacing: 24) {
            // Avatar picker
            PhotosPicker(selection: $viewModel.avatarItem, matching: .images) {
                ZStack {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 100, height: 100)
                    
                    if let image = viewModel.selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            VStack(spacing: 16) {
                TextField("Your Name", text: $viewModel.userName)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .textContentType(.name)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                
                Text("This will be visible to your contacts")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var continueButton: some View {
        Button {
            Task {
                await viewModel.continueTapped()
            }
        } label: {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Text(viewModel.continueButtonTitle)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(viewModel.isContinueEnabled ? Color.blue : Color.blue.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!viewModel.isContinueEnabled || viewModel.isLoading)
    }
}

// MARK: - Auth ViewModel

@MainActor
final class AuthViewModel: ObservableObject {
    enum Step {
        case phoneNumber
        case verification
        case profileSetup
    }
    
    @Published var currentStep: Step = .phoneNumber
    @Published var phoneNumber = ""
    @Published var codeDigits: [String] = Array(repeating: "", count: 6)
    @Published var userName = ""
    @Published var selectedCountry = CountryCode.default
    @Published var avatarItem: PhotosPickerItem?
    @Published var selectedImage: UIImage?
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var isAuthenticated = false
    @Published var resendTimer = 0
    @Published var canResendCode = false
    
    var currentCodeIndex: Int {
        codeDigits.firstIndex(where: { $0.isEmpty }) ?? 5
    }
    
    var formattedPhoneNumber: String {
        let cleaned = phoneNumber.filter { "0123456789".contains($0) }
        let masked = String(cleaned.prefix(10))
        if masked.count >= 6 {
            return "\(masked.prefix(3)) \(masked.dropFirst(3).prefix(3)) \(masked.dropFirst(6))"
        } else if masked.count >= 3 {
            return "\(masked.prefix(3)) \(masked.dropFirst(3))"
        }
        return masked
    }
    
    var fullPhoneNumber: String {
        "\(selectedCountry.code)\(phoneNumber.filter { "0123456789".contains($0) })"
    }
    
    var isContinueEnabled: Bool {
        switch currentStep {
        case .phoneNumber:
            return phoneNumber.filter { "0123456789".contains($0) }.count >= 7
        case .verification:
            return codeDigits.allSatisfy { !$0.isEmpty }
        case .profileSetup:
            return !userName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    
    var continueButtonTitle: String {
        switch currentStep {
        case .phoneNumber: return "Continue"
        case .verification: return "Verify"
        case .profileSetup: return "Get Started"
        }
    }
    
    private var resendTimerTask: Task<Void, Never>?
    
    func continueTapped() async {
        switch currentStep {
        case .phoneNumber:
            await sendCode()
        case .verification:
            await verifyCode()
        case .profileSetup:
            await completeProfile()
        }
    }
    
    func sendCode() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            try await APIService.shared.sendVerificationCode(phoneNumber: fullPhoneNumber)
            currentStep = .verification
            startResendTimer()
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    func verifyCode() async {
        isLoading = true
        defer { isLoading = false }
        
        let code = codeDigits.joined()
        
        do {
            let response = try await APIService.shared.verifyCode(
                phoneNumber: fullPhoneNumber,
                code: code,
                name: userName.isEmpty ? nil : userName
            )
            
            await AppState.shared.updateAuth(tokens: response)
            isAuthenticated = true
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    func completeProfile() async {
        isLoading = true
        defer { isLoading = false }
        
        // Upload avatar if selected
        var avatarUrl: String?
        if let image = selectedImage,
           let imageData = image.jpegData(compressionQuality: 0.8) {
            do {
                let upload = try await APIService.shared.uploadFile(
                    data: imageData,
                    filename: "avatar.jpg",
                    mimeType: "image/jpeg"
                )
                avatarUrl = upload.file.url
            } catch {
                print("Avatar upload failed: \(error)")
            }
        }
        
        do {
            _ = try await APIService.shared.updateProfile(
                name: userName,
                bio: nil,
                avatarUrl: avatarUrl
            )
            isAuthenticated = true
        } catch {
            showError(error.localizedDescription)
        }
    }
    
    private func startResendTimer() {
        resendTimerTask?.cancel()
        resendTimer = 60
        canResendCode = false
        
        resendTimerTask = Task {
            while resendTimer > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    resendTimer -= 1
                }
            }
            await MainActor.run {
                canResendCode = true
            }
        }
    }
    
    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Supporting Views

struct CodeDigitField: View {
    @Binding var text: String
    let isFocused: Bool
    let onTap: () -> Void
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
                .frame(width: 48, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? Color.blue : Color.clear, lineWidth: 2)
                )
            
            TextField("", text: $text)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .frame(width: 48, height: 56)
                .onChange(of: text) { _, newValue in
                    if newValue.count > 1 {
                        text = String(newValue.prefix(1))
                    }
                }
        }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Country Code Model

struct CountryCode: Identifiable {
    let id = UUID()
    let code: String
    let name: String
    let flag: String
    
    static let default = CountryCode(code: "+1", name: "United States", flag: "🇺🇸")
    
    static let commonCodes = [
        CountryCode(code: "+1", name: "United States/Canada", flag: "🇺🇸"),
        CountryCode(code: "+7", name: "Russia/Kazakhstan", flag: "🇷🇺"),
        CountryCode(code: "+44", name: "United Kingdom", flag: "🇬🇧"),
        CountryCode(code: "+33", name: "France", flag: "🇫🇷"),
        CountryCode(code: "+49", name: "Germany", flag: "🇩🇪"),
        CountryCode(code: "+86", name: "China", flag: "🇨🇳"),
        CountryCode(code: "+91", name: "India", flag: "🇮🇳"),
        CountryCode(code: "+81", name: "Japan", flag: "🇯🇵"),
        CountryCode(code: "+82", name: "South Korea", flag: "🇰🇷"),
        CountryCode(code: "+55", name: "Brazil", flag: "🇧🇷"),
        CountryCode(code: "+61", name: "Australia", flag: "🇦🇺"),
        CountryCode(code: "+41", name: "Switzerland", flag: "🇨🇭"),
    ]
}

import PhotosUI