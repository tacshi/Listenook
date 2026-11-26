//! Links the libmpv build of the target's platform (scripts/mpv-libraries.txt), fetching it into
//! vendor/mpv/<platform> first when it is not there.

use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

fn main() {
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let root = crate_dir().join("../..");
    println!("cargo:rerun-if-changed={}", root.join("scripts/mpv-libraries.txt").display());
    match os.as_str() {
        "macos" | "ios" => apple(&root, &os),
        "linux" => linux(),
        "android" => android(&root),
        "windows" => windows(&root),
        _ => {}
    }
}

/// This crate's folder. nsh builds app crates through a manifest of its own elsewhere
/// (`.nsh/rust/app-crates`), which names this script by its absolute path; Cargo names it
/// relative to the workspace when it builds the crate itself.
fn crate_dir() -> PathBuf {
    let script = Path::new(file!());
    match script.parent() {
        Some(dir) if script.is_absolute() => dir.to_path_buf(),
        _ => PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("Cargo sets CARGO_MANIFEST_DIR")),
    }
}

/// Fetches `platform`'s libmpv into vendor/mpv/<platform>: where it is.
fn fetch(root: &Path, platform: &str) -> PathBuf {
    let status = Command::new("bash")
        .arg(root.join("scripts/fetch-mpv.sh"))
        .arg(platform)
        .status()
        .expect("bash runs scripts/fetch-mpv.sh");
    assert!(status.success(), "scripts/fetch-mpv.sh {platform} failed");
    root.join("vendor/mpv").join(platform)
}

/// The LGPL libmpv-android build (scripts/mpv-libraries.txt): libmpv and FFmpeg's shared
/// libraries for the target's ABI, which the app's package carries (nsh.json's
/// `android.libraries`).
fn android(root: &Path) {
    let abi = match env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default().as_str() {
        "aarch64" => "arm64-v8a",
        "arm" => "armeabi-v7a",
        "x86_64" => "x86_64",
        _ => "x86",
    };
    let dir = root.join("vendor/mpv/android/jni").join(abi);
    if !dir.join("libmpv.so").exists() {
        println!("cargo:warning=no libmpv for Android in {}: see scripts/mpv-libraries.txt", dir.display());
    }
    println!("cargo:rustc-link-search=native={}", dir.display());
    println!("cargo:rustc-link-lib=dylib=mpv");
    println!("cargo:rustc-link-lib=dylib=avcodec");
}

/// libmpv-2.dll (scripts/fetch-mpv.ps1), which the app loads from its own folder: copied next
/// to what Cargo builds, so development builds find it too. Linking needs no import library
/// (`raw-dylib`).
fn windows(root: &Path) {
    let dll = root.join("vendor/mpv/windows/libmpv-2.dll");
    println!("cargo:rerun-if-changed={}", dll.display());
    let out = PathBuf::from(env::var("OUT_DIR").expect("Cargo sets OUT_DIR"));
    // OUT_DIR is <target>/<profile>/build/<crate>-<hash>/out.
    let Some(profile) = out.ancestors().nth(3) else { return };
    if dll.exists() {
        if let Err(why) = fs::copy(&dll, profile.join("libmpv-2.dll")) {
            println!("cargo:warning=libmpv-2.dll was not copied next to the app: {why}");
        }
    } else {
        println!("cargo:warning=no libmpv-2.dll in vendor/mpv/windows: run scripts/fetch-mpv.ps1");
    }
}

/// The system's libmpv (`libmpv-dev`, `mpv-libs-devel`, `mpv`), found with pkg-config.
fn linux() {
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    let found = Command::new("pkg-config").args(["--libs", "mpv"]).output().ok().filter(|out| out.status.success());
    let Some(found) = found else {
        println!(
            "cargo:warning=pkg-config found no libmpv: install libmpv-dev (Debian, Ubuntu) or mpv-libs-devel (Fedora)"
        );
        println!("cargo:rustc-link-lib=mpv");
        return;
    };
    for flag in String::from_utf8_lossy(&found.stdout).split_whitespace() {
        if let Some(dir) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={dir}");
        } else if let Some(library) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={library}");
        }
    }
}

/// MPVKit's static xcframeworks: each one's slice for the target, and what they link against.
fn apple(root: &Path, os: &str) {
    let dir = fetch(root, "apple");
    let simulator = env::var("TARGET").unwrap_or_default().ends_with("-sim")
        || env::var("CARGO_CFG_TARGET_ABI").is_ok_and(|abi| abi == "sim");
    let slice = |xcframework: &Path| -> Option<PathBuf> {
        fs::read_dir(xcframework).ok()?.flatten().map(|entry| entry.path()).find(|path| {
            let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("");
            match os {
                "macos" => name.starts_with("macos-"),
                _ if simulator => name.starts_with("ios-") && name.ends_with("-simulator"),
                _ => name.starts_with("ios-") && !name.contains('_') && !name.ends_with("-simulator"),
            }
        })
    };
    let mut entries: Vec<PathBuf> = fs::read_dir(&dir).expect("vendor/mpv/apple").flatten().map(|e| e.path()).collect();
    entries.sort();
    for xcframework in entries.iter().filter(|path| path.extension().is_some_and(|ext| ext == "xcframework")) {
        let name = xcframework.file_stem().and_then(|name| name.to_str()).expect("an xcframework's name");
        let Some(slice) = slice(xcframework) else { continue };
        if slice.join(format!("{name}.framework")).exists() {
            println!("cargo:rustc-link-search=framework={}", slice.display());
            println!("cargo:rustc-link-lib=framework={name}");
        } else if let Some(library) = fs::read_dir(&slice)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .find(|p| p.extension().is_some_and(|ext| ext == "a"))
        {
            println!("cargo:rustc-link-search=native={}", slice.display());
            let stem = library.file_stem().and_then(|stem| stem.to_str()).expect("a library's name");
            println!("cargo:rustc-link-lib=static:-bundle={}", stem.trim_start_matches("lib"));
        }
    }
    let frameworks = [
        "AVFoundation",
        "AudioToolbox",
        "CoreAudio",
        "CoreFoundation",
        "CoreMedia",
        "CoreText",
        "CoreVideo",
        "IOSurface",
        "Metal",
        "QuartzCore",
        "Security",
        "VideoToolbox",
    ];
    for framework in frameworks {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    if os == "macos" {
        println!("cargo:rustc-link-lib=framework=Cocoa");
        println!("cargo:rustc-link-lib=framework=IOKit");
    } else {
        println!("cargo:rustc-link-lib=framework=UIKit");
        // libmpv's OpenGL ES output and its VideoToolbox interop, which Listenook does not use.
        println!("cargo:rustc-link-lib=framework=OpenGLES");
    }
    for library in ["bz2", "c++", "expat", "iconv", "resolv", "xml2", "z"] {
        println!("cargo:rustc-link-lib={library}");
    }
    // libmpv's Apple code is partly Swift: the toolchain's Swift compatibility libraries, and
    // the SDK's Swift overlays it was built against.
    let sdk = match os {
        "macos" => "macosx",
        _ if simulator => "iphonesimulator",
        _ => "iphoneos",
    };
    let output = |args: &[&str]| -> Option<String> {
        let out = Command::new("xcrun").args(args).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
    };
    if let Some(sdk_path) = output(&["--sdk", sdk, "--show-sdk-path"]) {
        println!("cargo:rustc-link-search=native={sdk_path}/usr/lib/swift");
    }
    if let Some(swiftc) = output(&["--sdk", sdk, "--find", "swiftc"]) {
        let toolchain = Path::new(&swiftc).parent().and_then(Path::parent).expect("swiftc is in <toolchain>/usr/bin");
        println!("cargo:rustc-link-search=native={}", toolchain.join("lib/swift").join(sdk).display());
    }
}
