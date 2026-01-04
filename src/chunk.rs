use std::fs;
use std::path::Path;
use std::process::Command;

use crate::encoder::Encoder;

#[derive(Clone)]
pub struct Scene {
    pub s_frame: usize,
    pub e_frame: usize,
}

#[derive(Clone)]
pub struct Chunk {
    pub idx: usize,
    pub start: usize,
    pub end: usize,
}

#[derive(Clone)]
pub struct ChunkComp {
    pub idx: usize,
    pub frames: usize,
    pub size: u64,
}

#[derive(Clone)]
pub struct ResumeInf {
    pub chnks_done: Vec<ChunkComp>,
}

pub fn load_scenes(path: &Path, t_frames: usize) -> Result<Vec<Scene>, Box<dyn std::error::Error>> {
    let content = fs::read_to_string(path)?;
    let mut s_frames: Vec<usize> =
        content.lines().filter_map(|line| line.trim().parse().ok()).collect();

    s_frames.sort_unstable();

    let mut scenes = Vec::new();
    for i in 0..s_frames.len() {
        let s = s_frames[i];
        let e = s_frames.get(i + 1).copied().unwrap_or(t_frames);
        scenes.push(Scene { s_frame: s, e_frame: e });
    }

    Ok(scenes)
}

pub fn validate_scenes(
    scenes: &[Scene],
    fps_num: u32,
    fps_den: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    let max_len = ((fps_num * 10 + fps_den / 2) / fps_den).min(300);

    for (i, scene) in scenes.iter().enumerate() {
        let len = scene.e_frame.saturating_sub(scene.s_frame);

        if len == 0 || len > max_len as usize {
            return Err(format!(
                "Scene {} (frames {}-{}) has invalid length {}: must be up to {} frames",
                i, scene.s_frame, scene.e_frame, len, max_len
            )
            .into());
        }
    }

    Ok(())
}

pub fn chunkify(scenes: &[Scene]) -> Vec<Chunk> {
    scenes
        .iter()
        .enumerate()
        .map(|(i, s)| Chunk { idx: i, start: s.s_frame, end: s.e_frame })
        .collect()
}

pub fn get_resume(work_dir: &Path) -> Option<ResumeInf> {
    let path = work_dir.join("done.txt");
    path.exists()
        .then(|| {
            let content = fs::read_to_string(path).ok()?;
            let mut chnks_done = Vec::new();

            for line in content.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() == 3
                    && let (Ok(idx), Ok(frames), Ok(size)) = (
                        parts[0].parse::<usize>(),
                        parts[1].parse::<usize>(),
                        parts[2].parse::<u64>(),
                    )
                {
                    chnks_done.push(ChunkComp { idx, frames, size });
                }
            }

            Some(ResumeInf { chnks_done })
        })
        .flatten()
}

pub fn save_resume(data: &ResumeInf, work_dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let path = work_dir.join("done.txt");
    let mut content = String::new();

    for chunk in &data.chnks_done {
        use std::fmt::Write;
        let _ = writeln!(
            content,
            "{idx} {frames} {size}",
            idx = chunk.idx,
            frames = chunk.frames,
            size = chunk.size
        );
    }

    fs::write(path, content)?;
    Ok(())
}

fn concat_ivf(
    files: &[std::path::PathBuf],
    output: &Path,
    total_frames: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::{Read, Seek, SeekFrom, Write};

    let mut out = fs::File::create(output)?;

    for (i, file) in files.iter().enumerate() {
        let mut f = fs::File::open(file)?;
        if i != 0 {
            let mut buf = [0u8; 32];
            f.read_exact(&mut buf)?;
        }
        std::io::copy(&mut f, &mut out)?;
    }

    out.seek(SeekFrom::Start(24))?;
    out.write_all(&total_frames.to_le_bytes())?;

    Ok(())
}

#[cfg(target_os = "windows")]
const BATCH_SIZE: usize = usize::MAX;
#[cfg(not(target_os = "windows"))]
const BATCH_SIZE: usize = 960;

pub fn merge_out(
    encode_dir: &Path,
    output: &Path,
    inf: &crate::ffms::VidInf,
    input: Option<&Path>,
    timestamps: Option<&Path>,
    encoder: Encoder,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut files: Vec<_> = fs::read_dir(encode_dir)?
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "ivf"))
        .collect();

    files.sort_unstable_by_key(|e| {
        e.path()
            .file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(0)
    });

    if encoder == Encoder::Avm {
        return concat_ivf(
            &files.iter().map(fs::DirEntry::path).collect::<Vec<_>>(),
            output,
            inf.frames as u32,
        );
    }

    if files.len() <= BATCH_SIZE {
        return run_merge(
            &files.iter().map(fs::DirEntry::path).collect::<Vec<_>>(),
            output,
            inf,
            if let Some(path) = input
                && path.extension().is_some_and(|e| e.eq_ignore_ascii_case("y4m"))
            {
                None
            } else {
                input
            },
            timestamps,
        );
    }

    let temp_dir = encode_dir.join("temp_merge");
    fs::create_dir_all(&temp_dir)?;

    let batches: Vec<_> = files
        .chunks(BATCH_SIZE)
        .enumerate()
        .map(|(i, chunk)| {
            let path = temp_dir.join(format!("batch_{i}.ivf"));
            run_merge(
                &chunk.iter().map(fs::DirEntry::path).collect::<Vec<_>>(),
                &path,
                inf,
                None,
                None,
            )?;
            Ok(path)
        })
        .collect::<Result<_, Box<dyn std::error::Error>>>()?;

    run_merge(&batches, output, inf, input, timestamps)?;
    fs::remove_dir_all(&temp_dir)?;
    Ok(())
}

fn run_merge(
    files: &[std::path::PathBuf],
    output: &Path,
    inf: &crate::ffms::VidInf,
    input: Option<&Path>,
    timestamps: Option<&Path>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut cmd = Command::new("mkvmerge");
    let mut args = vec![
        "-q".to_string(),
        "-o".to_string(),
        output.to_string_lossy().into_owned(),
        "-B".to_string(),
        "-T".to_string(),
    ];

    if input.is_none() {
        args.push("-A".to_string());
    }

    if let Some(ts_path) = timestamps {
        args.push("--timestamps".to_string());
        args.push(format!("0:{}", ts_path.display()));
    }

    args.extend([
        "--no-global-tags".to_string(),
        "--no-date".to_string(),
        "--disable-language-ietf".to_string(),
        "--disable-track-statistics-tags".to_string(),
    ]);

    if let (Some(dw), Some(dh)) = (inf.display_width, inf.display_height)
        && (dw != inf.width || dh != inf.height)
    {
        args.push("--aspect-ratio".to_string());
        args.push(format!("0:{dw}/{dh}"));
    }

    args.push("--default-duration".to_string());
    args.push(format!("0:{}/{}fps", inf.fps_num, inf.fps_den));

    for (i, file) in files.iter().enumerate() {
        if i != 0 {
            args.push("+".to_string());
        }
        args.push(file.to_string_lossy().into_owned());
    }

    if let Some(input) = input {
        args.push("-D".to_string());
        args.push(input.to_string_lossy().into_owned());
    }

    if cfg!(target_os = "windows") {
        let json_args = sonic_rs::to_string(&args)?;
        let opts_file = output.with_file_name(format!(
            "{}.opts.json",
            output.file_name().unwrap_or_default().to_string_lossy()
        ));
        fs::write(&opts_file, json_args)?;

        cmd.arg(format!("@{}", opts_file.display()));

        // eprintln!("\nOptions file: {}", opts_file.display());
        let status = cmd.status();

        let _ = fs::remove_file(&opts_file);

        if !status?.success() {
            return Err("Muxing failed".into());
        }
    } else {
        cmd.args(args);
        // eprintln!("\nRunning mkvmerge: {:?}", cmd);
        let status = cmd.status()?;
        if !status.success() {
            return Err("Muxing failed".into());
        }
    }
    Ok(())
}
