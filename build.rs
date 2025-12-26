use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    if cfg!(target_os = "windows") {
        build_windows();
    } else {
        build_unix();
    }
}

fn build_windows() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();

    if cfg!(feature = "dynamic") {
        println!("cargo:rustc-link-lib=ffms2");
        #[cfg(feature = "vship")]
        println!("cargo:rustc-link-lib=libvship");
    }

    if cfg!(feature = "static") {
        let mut lib_path = PathBuf::from(&manifest_dir);
        lib_path.push("lib");
        println!("cargo:rustc-link-search=native={}", lib_path.display());

        #[cfg(feature = "vship")]
        {
            if !cfg!(feature = "amd") && !cfg!(feature = "nvidia") {
                println!(
                    "cargo:warning=The 'vship' feature is enabled, but neither 'amd' nor 'nvidia' \
                     is selected. Please enable one, e.g., --features vship,amd"
                );
            }

            #[cfg(feature = "amd")]
            {
                println!("cargo:rustc-link-lib=static=libvship-amd");
                match env::var("HIP_PATH") {
                    Ok(hip_path) => {
                        let hip_lib_path = std::path::Path::new(&hip_path).join("lib");
                        println!("cargo:rustc-link-search=native={}", hip_lib_path.display());
                    }
                    Err(_) => {
                        println!("cargo:warning=HIP_PATH environment variable not set.");
                    }
                }
                println!("cargo:rustc-link-lib=static=amdhip64");
            }

            #[cfg(feature = "nvidia")]
            {
                println!("cargo:rustc-link-lib=static=libvship");
                match env::var("CUDA_PATH") {
                    Ok(cuda_path) => {
                        let cuda_lib_path =
                            std::path::Path::new(&cuda_path).join("lib").join("x64");
                        println!("cargo:rustc-link-search=native={}", cuda_lib_path.display());
                        println!("cargo:rustc-link-lib=static=cudart_static");
                    }
                    Err(_) => {
                        println!("cargo:warning=CUDA_PATH environment variable not set.");
                    }
                }
                println!("cargo:rustc-link-lib=static=cudart_static");
            }
        }

        #[cfg(feature = "use-vcpkg")]
        {
            vcpkg::Config::new()
                .emit_includes(true)
                .find_package("ffmpeg")
                .expect("Failed to find ffmpeg via vcpkg");
        }

        #[cfg(not(feature = "use-vcpkg"))]
        {
            let mut ffmpeg_lib_path = PathBuf::from(&manifest_dir);
            ffmpeg_lib_path.push("ffmpeg");
            ffmpeg_lib_path.push("lib");
            println!("cargo:rustc-link-search=native={}", ffmpeg_lib_path.display());

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

        let sys_libs = ["bcrypt", "mfuuid", "strmiids", "advapi32", "crypt32", "user32", "ole32"];
        for lib in sys_libs {
            println!("cargo:rustc-link-lib={}", lib);
        }
    }
}

fn build_unix() {
    let libs = [
        "libavformat",
        "libavcodec",
        "libswscale",
        "libswresample",
        "libavutil",
        "dav1d",
        "zlib",
        "libssl",
        "libcrypto",
        "libxml-2.0",
        "liblzma",
    ];

    for lib in libs {
        if let Err(e) = pkg_config::probe_library(lib) {
            println!("cargo:warning=pkg-config could not find {}: {}", lib, e);
        }
    }

    if let Ok(home) = env::var("HOME") {
        let local_src = PathBuf::from(&home).join(".local/src");

        let add_search = |path: PathBuf| {
            if path.exists() {
                println!("cargo:rustc-link-search=native={}", path.display());
            }
        };

        add_search(local_src.join("FFmpeg/install/lib"));
        add_search(local_src.join("dav1d/build/src"));
        add_search(local_src.join("zlib/install/lib"));
    }

    #[cfg(feature = "vship")]
    {
        if let Ok(home) = env::var("HOME") {
            println!("cargo:rustc-link-search=native={}/.local/src/Vship", home);
        }
        println!("cargo:rustc-link-lib=static=vship");
        println!("cargo:rustc-link-lib=static=cudart_static");
        println!("cargo:rustc-link-search=native=/opt/cuda/lib64");
        println!("cargo:rustc-link-lib=dylib=cuda");
    }
}
