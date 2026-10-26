# Blink Messenger - GitHub Actions IPA Build Setup

## Prerequisites

1. **Apple Developer Account** - Enroll in the Apple Developer Program
2. **GitHub Secrets** - Add the following secrets to your repository:
   - `APPLE_ID` - Your Apple ID email
   - `APPLE_PASSWORD` - Apple ID password (or app-specific password)
   - `APPLE_IOS_PROVISIONING_PROFILE` - Base64 encoded provisioning profile
   - `MATCH_GIT_PRIVATE_KEY` - Optional: Base64 encoded private key for Match
   - `TEAM_ID` - Your Apple Developer Team ID

## Step 1: Create Provisioning Profile

```bash
# Generate provisioning profile from Apple Developer Console
# Then base64 encode it:
base64 -p your-profile.mobileprovision > profile.b64

# Add to GitHub Secrets:
# APPLE_IOS_PROVISIONING_PROFILE: $(cat profile.b64)
```

## Step 2: Create Apple Auth Key (Recommended)

For easier CI/CD, create an Apple key:

```bash
# Generate key from Apple Developer Account
# Save as p8 file, then base64 encode
base64 -i AuthKey.p8 > auth_key.b64

# Add to GitHub Secrets:
# MATCH_GIT_PRIVATE_KEY: $(cat auth_key.b64)
```

## Step 3: Enable Xcode Select

The GitHub Actions runner has Xcode pre-installed on macOS-latest. No additional setup needed.

## Step 4: Project Configuration

### Open in Xcode
1. Open `BlinkMessenger.xcworkspace` in Xcode
2. Select the project target
3. Go to **Signing & Capabilities**
4. Turn off automatic signing
5. Set Code Signing Identity to `iPhone Distribution`
6. Set Provisioning Profile to your selected profile

### Required Capabilities
- Push Notifications (if using)
- Background Modes (Audio, AirPlay, Voice over IP)
- Associated Domains (if using universal links)

## Step 5: CocoaPods Setup (if using pods)

If any of your Swift packages use CocoaPods:

```bash
cd iOS/BlinkMessenger
pod setup
pod install
```

Ensure `Podfile` exists and run `pod install` locally before pushing.

## Step 6: Directory Structure

Ensure your project structure is:
```
BlinkMessenger/
├── iOS/BlinkMessenger.xcodeproj/    # Xcode project
├── iOS/BlinkMessenger/              # Swift source files
├── .github/workflows/build-ipa.yml  # GitHub Actions workflow
└── exportOptions.plist              # Export configuration
```

## Step 7: Test Locally First

Before committing to GitHub Actions, test the build locally:

```bash
# On a Mac with Xcode installed
cd BlinkMessenger/iOS/BlinkMessenger

# Open in Xcode
open BlinkMessenger.xcodeproj

# Product > Archive
# Or use xcodebuild:
xcodebuild -workspace BlinkMessenger.xcworkspace \
  -scheme BlinkMessenger \
  -configuration Release \
  -archivePath build/BlinkMessenger.xcarchive \
  CODE_SIGN_IDENTITY="iPhone Distribution" \
  PROVISIONING_PROFILE="your-profile-uuid"

# Export IPA
xcodebuild -exportArchive \
  -archivePath build/BlinkMessenger.xcarchive \
  -exportPath build/BlinkMessenger \
  -exportOptionsPlist exportOptions.plist
```

## GitHub Secrets Checklist

| Secret | Description | Example |
|--------|-------------|---------|
| `APPLE_ID` | Apple ID email | `dev@blink.im` |
| `APPLE_PASSWORD` | Apple ID password or app-specific password | `appl€password123` |
| `APPLE_IOS_PROVISIONING_PROFILE` | Base64 encoded provisioning profile | `base64(data)` |
| `MATCH_GIT_PRIVATE_KEY` | Base64 encoded private key for Match | `-----BEGIN EC PRIVATE KEY-----` |
| `TEAM_ID` | 10-character Apple Developer Team ID | `ABCD1234EF` |

## Workflow Triggers

The workflow runs on:
- `push` to `main` or `develop` branches
- `pull_request` against `main` branch

## Customizing the Build

### Change Scheme Name
Edit `.github/workflows/build-ipa.yml` and modify:
```yaml
-xcodebuild -scheme BlinkMessenger
```
to your actual scheme name.

### Change Build Configuration
Modify the `configuration` parameter:
```yaml
-xcodebuild -configuration Release
```
or use `Debug` for testing.

### Export Method
Change the `method` in `exportOptions.plist`:
- `development` - For testing on devices
- `ad-hoc` - For Ad Hoc distribution
- `app-store` - For App Store Connect
- `enterprise` - For in-house distribution
- `package` - For B2B distribution

## Troubleshooting

### Common Issues

1. **Code Signing Error**
   - Ensure provisioning profile is correctly installed
   - Verify Code Signing Identity matches
   - Check that team ID is correct

2. **Provisioning Profile Not Found**
   - Ensure `PROVISIONING_PROFILE_SPECIFIER` matches the profile name
   - Or use UUID instead of name

3. **Failed to Parse Info.plist**
   - Ensure `CFBundleIdentifier` is set correctly
   - Check for duplicate values

4. **IB Internal Inconsistency**
   - Run `Product > Clean Build Folder`
   - Delete `DerivedData` and rebuild

5. **Entitlements Failed**
   - Enable required capabilities in Xcode
   - Add entitlements to the project settings

## Output

Upon successful build, the IPA will be available as a GitHub Artifact:
- **Name**: `BlinkMessenger.ipa`
- **Path**: `iOS/BlinkMessenger/build/BlinkMessenger.ipa`
- **Retention**: 30 days

You can download the IPA from the Actions tab in your GitHub repository.

## Next Steps After Build

1. **TestFlight** - Upload to TestFlight for beta testing
2. **App Store Connect** - Submit for App Store review
3. **Deployment** - Distribute to internal testers via Ad Hoc

---

**Need help?** If you encounter specific errors during the build process, check the GitHub Actions logs or consult the Apple Developer documentation for code signing requirements.