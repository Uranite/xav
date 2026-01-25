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

    if !cfg!(feature = "static") {
        println!("cargo:rustc-link-lib=ffms2");
        #[cfg(feature = "vship")]
        println!("cargo:rustc-link-lib=libvship");
    } else {
        println!("cargo:rustc-link-lib=static=ffms2");
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
    if !cfg!(feature = "static") {
        println!("cargo:rustc-link-lib=ffms2");
        #[cfg(feature = "vship")]
        println!("cargo:rustc-link-lib=vship");
    } else {
        let home = env::var("HOME").expect("HOME environment variable not set");
        println!("cargo:rustc-link-search=native={home}/.local/src/FFmpeg/install/lib");
        println!("cargo:rustc-link-search=native={home}/.local/src/dav1d/build/src");
        println!("cargo:rustc-link-search=native={home}/.local/src/zlib/install/lib");

        println!("cargo:rustc-link-lib=static=swscale");
        println!("cargo:rustc-link-lib=static=avformat");
        println!("cargo:rustc-link-lib=static=avcodec");
        println!("cargo:rustc-link-lib=static=avutil");
        println!("cargo:rustc-link-lib=static=dav1d");
        println!("cargo:rustc-link-lib=static=z");
        println!("cargo:rustc-link-lib=static=stdc++");

        #[cfg(feature = "vship")]
        {
            println!("cargo:rustc-link-search=native={home}/.local/src/Vship");

            println!("cargo:rustc-link-lib=static=vship");

            println!("cargo:rustc-link-lib=static=cudart_static");
            println!("cargo:rustc-link-search=native=/opt/cuda/lib64");

            println!("cargo:rustc-link-lib=dylib=cuda");
        }
    }

    if cfg!(feature = "libsvtav1") {
        let home = env::var("HOME").expect("HOME environment variable not set");
        let search_paths = [
            format!("{home}/.local/src/svt-av1-hdr/Bin/Release"),
            format!("{home}/.local/src/SVT-AV1/Bin/Release"),
            "/usr/lib64".to_string(),
            "/usr/lib".to_string(),
            "/lib64".to_string(),
            "/lib".to_string(),
        ];
        for path in &search_paths {
            if std::path::Path::new(&format!("{path}/libSvtAv1Enc.a")).exists() {
                println!("cargo:rustc-link-search=native={path}");
                break;
            }
        }
        println!("cargo:rustc-link-lib=static=SvtAv1Enc");
    }
}
