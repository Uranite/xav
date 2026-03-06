use std::{
    env,
    path::{Path, PathBuf},
    process,
};

const SYS_PATHS: [&str; 6] = [
    "/usr/lib64",
    "/usr/lib",
    "/usr/local/lib64",
    "/usr/local/lib",
    "/lib64",
    "/lib",
];

fn find_static_lib(primary_paths: &[String], lib_name: &str) {
    for path in primary_paths
        .iter()
        .map(String::as_str)
        .chain(SYS_PATHS.iter().copied())
    {
        if Path::new(&format!("{path}/{lib_name}")).exists() {
            println!("cargo:rustc-link-search=native={path}");
            return;
        }
    }
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=lib");
    if cfg!(target_os = "windows") {
        build_windows();
    } else {
        build_unix();
    }
}

fn build_windows() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();

    if !cfg!(feature = "static") {
        println!("cargo:rustc-link-lib=ffms2");
        println!("cargo:rustc-link-lib=opusenc");
        println!("cargo:rustc-link-lib=opus");
        #[cfg(feature = "vship")]
        println!("cargo:rustc-link-lib=libvship");
        println!("cargo:rustc-link-lib=SvtAv1Enc");
    } else {
        let mut lib_path = PathBuf::from(&manifest_dir);
        lib_path.push("lib");
        println!("cargo:rustc-link-search=native={}", lib_path.display());
        println!("cargo:rustc-link-lib=static=ffms2");
        println!("cargo:rustc-link-lib=static=opusenc");
        println!("cargo:rustc-link-lib=static=opus");
        println!("cargo:rustc-link-lib=static=SvtAv1Enc");

        #[cfg(feature = "vship")]
        {
            if !cfg!(feature = "amd") && !cfg!(feature = "nvidia") {
                println!(
                    "cargo:warning=The 'vship' feature is enabled, but neither 'amd' nor 'nvidia' \
                     is selected. Please enable one, e.g., --features vship,amd (ignore if you're \
                     compiling with vulkan vship)"
                );
                println!(
                    "cargo:warning=amd and nvidia feature not selected, defaulting to Vulkan."
                );
                match env::var("VULKAN_SDK") {
                    Ok(vulkan_path) => {
                        let vulkan_lib_path = std::path::Path::new(&vulkan_path).join("Lib");
                        println!(
                            "cargo:rustc-link-search=native={}",
                            vulkan_lib_path.display()
                        );
                    }
                    Err(_) => {
                        println!("cargo:warning=VULKAN_SDK environment variable not set.");
                    }
                }
                println!("cargo:rustc-link-lib=static=vulkan-1");
            }

            println!("cargo:rustc-link-lib=static=libvship");

            #[cfg(feature = "amd")]
            match env::var("HIP_PATH") {
                Ok(hip_path) => {
                    let hip_lib_path = std::path::Path::new(&hip_path).join("lib");
                    println!("cargo:rustc-link-search=native={}", hip_lib_path.display());
                }
                Err(_) => {
                    println!("cargo:warning=HIP_PATH environment variable not set.");
                }
            }
            #[cfg(feature = "amd")]
            println!("cargo:rustc-link-lib=static=amdhip64");
            #[cfg(feature = "nvidia")]
            match env::var("CUDA_PATH") {
                Ok(cuda_path) => {
                    let cuda_lib_path = std::path::Path::new(&cuda_path).join("lib").join("x64");
                    println!("cargo:rustc-link-search=native={}", cuda_lib_path.display());
                }
                Err(_) => {
                    println!("cargo:warning=CUDA_PATH environment variable not set.");
                }
            }
            #[cfg(feature = "nvidia")]
            println!("cargo:rustc-link-lib=static=cudart_static");
        }

        #[cfg(feature = "vcpkg")]
        {
            vcpkg::Config::new()
                .emit_includes(true)
                .find_package("ffmpeg")
                .expect("Failed to find ffmpeg via vcpkg");
        }

        #[cfg(not(feature = "vcpkg"))]
        {
            let mut ffmpeg_lib_path = PathBuf::from(&manifest_dir);
            ffmpeg_lib_path.push("ffmpeg");
            ffmpeg_lib_path.push("lib");
            println!(
                "cargo:rustc-link-search=native={}",
                ffmpeg_lib_path.display()
            );

            let libs = [
                "avformat",
                "avcodec",
                "swscale",
                "swresample",
                "avutil",
                "lzma",
                "dav1d",
                "bcrypt",
                "zlib",
                "libssl",
                "libcrypto",
                "iconv",
                "libxml2",
                "bz2",
            ];
            for lib in libs {
                println!("cargo:rustc-link-lib=static={}", lib);
            }
        }

        let sys_libs = [
            "bcrypt", "mfuuid", "strmiids", "advapi32", "crypt32", "user32", "ole32",
        ];
        for lib in sys_libs {
            println!("cargo:rustc-link-lib={}", lib);
        }
    }
}

fn build_unix() {
    let home = env::var("HOME").unwrap_or_else(|_| {
        println!("cargo:warning=HOME environment variable not set");
        process::exit(1);
    });

    println!("cargo:rustc-link-search=native={home}/.local/src/FFmpeg/install/lib");
    println!("cargo:rustc-link-search=native={home}/.local/src/dav1d/build/src");
    println!("cargo:rustc-link-search=native={home}/.local/src/vulkan/install/lib");

    println!("cargo:rustc-link-lib=static=swresample");
    println!("cargo:rustc-link-lib=static=avformat");
    println!("cargo:rustc-link-lib=static=avcodec");
    println!("cargo:rustc-link-lib=static=avutil");
    println!("cargo:rustc-link-lib=static=vulkan");
    println!("cargo:rustc-link-lib=static=dav1d");

    find_static_lib(
        &[format!("{home}/.local/src/opus/install/lib")],
        "libopus.a",
    );
    find_static_lib(
        &[format!("{home}/.local/src/libopusenc/install/lib")],
        "libopusenc.a",
    );
    println!("cargo:rustc-link-lib=static=opusenc");
    println!("cargo:rustc-link-lib=static=opus");

    find_static_lib(
        &[format!("{home}/.local/src/SVT-AV1/Bin/Release")],
        "libSvtAv1Enc.a",
    );
    println!("cargo:rustc-link-lib=static=SvtAv1Enc");

    #[cfg(feature = "vship")]
    {
        let vship_dir = format!("{home}/.local/src/Vship");
        if Path::new(&format!("{vship_dir}/libvship.a")).exists() {
            println!("cargo:rustc-link-search=native={vship_dir}");
            println!("cargo:rustc-link-lib=static=vship");
        } else {
            println!("cargo:rustc-link-lib=dylib=vship");
            return;
        }
        println!("cargo:rustc-link-lib=static=stdc++");
        println!("cargo:rustc-link-lib=static=cudart_static");
        println!("cargo:rustc-link-search=native=/opt/cuda/lib64");
        println!("cargo:rustc-link-lib=dylib=cuda");
    }
}
