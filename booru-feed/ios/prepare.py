"""Create the Xcode project and icon; run pod install on macOS for VLC."""
import json
import os
import plistlib
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent


def prepare():
    objects = {}

    def add(identifier, isa, **values):
        import hashlib
        key = hashlib.sha256(identifier.encode()).hexdigest()[:24].upper()
        objects[key] = dict(isa=isa, **values)
        return key

    sources = [add(name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=name, sourceTree="<group>") for name in ("LocalMediaApp.swift", "MediaFiles.swift")]
    assets = add("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="<group>")
    privacy = add("privacy", "PBXFileReference", lastKnownFileType="text.xml", path="PrivacyInfo.xcprivacy", sourceTree="<group>")
    license_file = add("license", "PBXFileReference", lastKnownFileType="text", path="VLC-LICENSE.txt", sourceTree="<group>")
    product = add("product", "PBXFileReference", explicitFileType="wrapper.application", path="LocalMediaPlayer.app", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", "PBXGroup", children=[product], name="Products", sourceTree="<group>")
    group = add("group", "PBXGroup", children=sources + [assets, privacy, license_file, products], sourceTree="<group>")
    build_sources = [add("build" + key, "PBXBuildFile", fileRef=key) for key in sources]
    build_resources = [add("build" + key, "PBXBuildFile", fileRef=key) for key in [assets, privacy, license_file]]
    phases = [add("sourcePhase", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_sources, runOnlyForDeploymentPostprocessing=0), add("frameworkPhase", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0), add("resourcePhase", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=build_resources, runOnlyForDeploymentPostprocessing=0)]
    settings = dict(SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="17.0", SDKROOT="iphoneos", TARGETED_DEVICE_FAMILY="1,2", PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.toomiiverse.localmediaplayer", GENERATE_INFOPLIST_FILE="NO", INFOPLIST_FILE="Info.plist", CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="1.0", CODE_SIGN_STYLE="Automatic", ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", SWIFT_EMIT_LOC_STRINGS="YES", ENABLE_USER_SCRIPT_SANDBOXING="YES", SUPPORTS_MACCATALYST="NO", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks")
    if os.environ.get("PROFILE_UUID"):
        settings.update(CODE_SIGN_STYLE="Manual", DEVELOPMENT_TEAM=os.environ["APPLE_TEAM_ID"], PRODUCT_BUNDLE_IDENTIFIER=os.environ["IOS_BUNDLE_ID"], PROVISIONING_PROFILE_SPECIFIER=os.environ["PROFILE_UUID"], CODE_SIGN_IDENTITY="Apple Distribution")
    # CocoaPods embeds the prebuilt VLC framework using its generated script.
    settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
    target_configs = [add("target" + name, "XCBuildConfiguration", name=name, buildSettings=dict(settings, SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG" if name == "Debug" else "", SWIFT_OPTIMIZATION_LEVEL="-Onone" if name == "Debug" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if name == "Debug" else "dwarf-with-dsym")) for name in ["Debug", "Release"]]
    project_configs = [add("project" + name, "XCBuildConfiguration", name=name, buildSettings=dict(CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES")) for name in ["Debug", "Release"]]
    target_list = add("targetList", "XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    project_list = add("projectList", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = add("target", "PBXNativeTarget", name="LocalMediaPlayer", productName="LocalMediaPlayer", productType="com.apple.product-type.application", productReference=product, buildConfigurationList=target_list, buildPhases=phases, buildRules=[], dependencies=[])
    project = add("project", "PBXProject", buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target], attributes=dict(LastUpgradeCheck="2600"))

    def pbx(value):
        if isinstance(value, dict):
            return "{\n" + "\n".join(f"{json.dumps(k)} = {pbx(v)};" for k, v in value.items()) + "\n}"
        if isinstance(value, list):
            return "(" + ",".join(map(pbx, value)) + ",)" if value else "()"
        return json.dumps(value)

    project_path = ROOT / "LocalMediaPlayer.xcodeproj"
    project_path.mkdir(exist_ok=True)
    (project_path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + pbx(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)), encoding="utf-8")
    schemes = project_path / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="LocalMediaPlayer.app" BlueprintName="LocalMediaPlayer" ReferencedContainer="container:LocalMediaPlayer.xcodeproj"/>'
    (schemes / "LocalMediaPlayer.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''', encoding="utf-8")
    orientations = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
    info = dict(CFBundleDisplayName="Local Media Player", CFBundleName="$(PRODUCT_NAME)", CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleExecutable="$(EXECUTABLE_NAME)", CFBundlePackageType="APPL", CFBundleShortVersionString="$(MARKETING_VERSION)", CFBundleVersion="$(CURRENT_PROJECT_VERSION)", LSRequiresIPhoneOS=True, UILaunchScreen={}, UISupportedInterfaceOrientations=orientations, ITSAppUsesNonExemptEncryption=False, UIApplicationSceneManifest=dict(UIApplicationSupportsMultipleScenes=False))
    info["UISupportedInterfaceOrientations~ipad"] = orientations + ["UIInterfaceOrientationPortraitUpsideDown"]
    (ROOT / "Info.plist").write_bytes(plistlib.dumps(info))
    (ROOT / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(dict(NSPrivacyTracking=False, NSPrivacyTrackingDomains=[], NSPrivacyCollectedDataTypes=[], NSPrivacyAccessedAPITypes=[dict(NSPrivacyAccessedAPIType="NSPrivacyAccessedAPICategoryUserDefaults", NSPrivacyAccessedAPITypeReasons=["CA92.1"])])))

    # Opaque RGB icon, with no imported assets or alpha channel.
    assets_path = ROOT / "Assets.xcassets"
    icon_path = assets_path / "AppIcon.appiconset"
    icon_path.mkdir(parents=True, exist_ok=True)
    (assets_path / "Contents.json").write_text(json.dumps(dict(info=dict(author="xcode", version=1))))
    (icon_path / "Contents.json").write_text(json.dumps(dict(images=[dict(filename="AppIcon.png", idiom="universal", platform="ios", size="1024x1024")], info=dict(author="xcode", version=1))))
    pixels = bytearray()
    for y in range(1024):
        pixels.append(0)
        for x in range(1024):
            triangle = 355 <= x <= 735 and abs(y - 512) <= (735 - x) * 0.72
            pixels.extend((245, 173, 203) if triangle else (43, 32, 47))

    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))
    (icon_path / "AppIcon.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    assert len(objects) == len(set(objects))
    assert all((ROOT / name).is_file() for name in ("LocalMediaApp.swift", "MediaFiles.swift", "Info.plist", "PrivacyInfo.xcprivacy"))
    print("Prepared LocalMediaPlayer.xcodeproj, icon and privacy manifest.")


if __name__ == "__main__":
    prepare()
