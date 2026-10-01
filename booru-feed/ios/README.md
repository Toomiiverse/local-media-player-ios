# Local Media Player for iPhone

A private, standalone iOS 17+ app for folders selected in Files, including attached drives. It does not connect to the desktop, Tailscale, booru sites or analytics services. Files are played in place; only the folder bookmark and shuffle preference are retained on the phone. File providers may download their own cloud files when opened.

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

Before relying on a TestFlight release, verify MP4/H.264, MKV/HEVC, AVI and WebM using your own non-sensitive fixtures; pause, seek, mute, speed, automatic next; selecting a USB drive in Files; folder restore after relaunch; drive removal during playback; cancelling a large scan; accessibility text sizes; portrait/landscape; and offline playback. Simulator compilation alone does not establish physical-drive access or every codec's playback.

References: [Apple TestFlight internal testing](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers), [Apple uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [GitHub signing on cloud Macs](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), [VideoLAN VLCKit](https://github.com/videolan/vlckit).
