# Local Media Player for iPhone

A private iOS 17+ app with two halves: a native client for Booru Feed running on your PC, and a player for folders selected in Files, including attached drives. Local files are played in place. File providers may download their own cloud files when opened.

**Booru Feed on your PC.** Five native tabs - Home, Search, Videos, Manga and Saved - read the PC app over its mobile access service; nothing is fetched from a board by the phone itself. The PC address is remembered on the phone; HTTPS is required and credentials, query strings and fragments are rejected. Keep the PC app and its mobile access service running, and connect Tailscale on both devices. Pair using the code shown in the desktop mobile access settings when prompted. Board API keys and browser sessions stay on the PC. Likes, saves, filters and manga preference tags are the same shared state the desktop and web versions use. The web version is still available from Saved → Settings → Web version, and is where pairing happens. Similar posts, recommendations and manga catalogue searches are worked out on the PC, so rule changes there reach the phone without an app update; the quick-filter and manga search rules that run on the phone are mirrored in `NativeState.swift` and checked by `NativeStateCheck.swift`. PC access requires the PC to be online; local playback remains available offline.

**On this iPhone.** Choose one or more folders or drives in Files (the picker allows several at once, and more can be added later). With several chosen, the library opens on the list of folders; each is browsed and shuffled on its own, and Settings lists them with a Forget button each. Only the folder in use keeps its permission open. Full screen puts the media edge to edge under the status bar and home indicator: a tap shows the controls for a few seconds, a double tap fills the screen (cropping the edges), swiping up or down moves to the next or previous file, and turning the phone sideways enters it automatically.

Uses MobileVLCKit **3.7.4**, the stable VLC engine, for broad codec/container support including MKV, AVI, MP4, MOV, WebM and WMV. Actual decoding depends on the file and device; damaged files and DRM protection are not bypassed. Images use bounded still previews, including the first frame of GIFs. Playback has seek, pause, mute, speed, previous/next and automatic next video. Backgrounding pauses playback.

Folders render 30 rows initially. Recursive shuffle samples at most 1,000 files, without loading their media into memory. Symlinks are skipped, access stays within the chosen folder, scans are cancellable, and forgetting a folder removes its saved permission bookmark without deleting media. Large directories still require reading their names before sorting; scanning runs away from the UI thread.

## Cloud build

`.github/workflows/ios-player.yml` uses a GitHub-hosted Mac. Pushes run the scanner checks and an unsigned simulator build. No Apple credentials are needed for these checks. GitHub macOS build minutes are charged against the account's included allowance/billing settings.

Publishing requires these **repository secrets**, entered through GitHub Settings → Secrets and variables → Actions, never committed or pasted into chat:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `IOS_CERTIFICATE_BASE64` | Base64 of an Apple Distribution certificate plus private key exported as `.p12` |
| `IOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `IOS_PROFILE_BASE64` | Base64 of its matching App Store distribution provisioning profile |
| `ASC_KEY_ID` | App Store Connect team API key ID |
| `ASC_ISSUER_ID` | API issuer ID |
| `ASC_PRIVATE_KEY` | Complete contents of the API `.p8` key, with upload permissions |

Set repository **variable** `IOS_BUNDLE_ID` to your registered app ID (suggested `com.toomiiverse.localmediaplayer`). Create a matching iOS app record in App Store Connect. Certificates can be requested using a CSR generated on Windows; a personal Mac is not required for the cloud build. If no distribution certificate exists, generate the private key/CSR locally and submit the CSR through Apple Developer Certificates, then combine the downloaded certificate and private key into the password-protected P12. Keep those files outside this repository.

To encode an existing certificate or profile on Windows without printing its contents, replace the example path and run this in PowerShell, then paste directly into the matching GitHub secret:

```powershell
Set-Clipboard -Value ([Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\distribution.p12')))
```

Repeat for the `.mobileprovision` file. `ASC_PRIVATE_KEY` uses the original `.p8` text, not Base64. Clear the clipboard afterward. Do not send these values through chat.

Run Actions → Private iOS player → Run workflow, enabling **Upload signed build to private TestFlight**. The script validates the provisioning profile and archives/exports an internal-testing-only build, then validates and uploads it. Signing files are removed from the temporary runner on exit. Upload success is not installation: wait for Apple processing, then create an internal TestFlight group and add your own App Store Connect user and processed build. No public testing link or App Store release is created. TestFlight builds expire after 90 days.

## Local build on a Mac / relinking

```
python3 prepare.py
pod install
swiftc MediaFiles.swift MediaFilesCheck.swift -o /tmp/media-check
/tmp/media-check
open LocalMediaPlayer.xcworkspace
```

Select your signing team in Xcode, then run on iPhone or archive. `prepare.py` generates the project, icon and privacy manifest; rerun `pod install` after regenerating. App source, build files and the pinned VLC pod allow rebuilding and relinking against a modified VLC build. VLCKit remains unmodified. Its LGPL license is included in the app's Open-source notices. Source and library build instructions: https://code.videolan.org/videolan/VLCKit/-/tree/3.7.4 . Give any additional private testers access to these app/build sources and the linked library sources when distributing.

## Device acceptance checks

Before relying on a TestFlight release, verify MP4/H.264, MKV/HEVC, AVI and WebM using your own non-sensitive fixtures; pause, seek, mute, speed, automatic next; selecting a USB drive in Files; choosing two folders at once, adding a third later and forgetting one; folders restored after relaunch (including the single folder an older build remembered); full screen in portrait and landscape with tap, double tap and the seek bar; drive removal during playback; cancelling a large scan; accessibility text sizes; portrait/landscape; and offline playback. Simulator compilation alone does not establish physical-drive access or every codec's playback.

References: [Apple TestFlight internal testing](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers), [Apple uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [GitHub signing on cloud Macs](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), [VideoLAN VLCKit](https://github.com/videolan/vlckit).
