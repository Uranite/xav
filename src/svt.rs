use core::{ffi::c_void, mem::offset_of};

pub const EB_ERROR_NONE: i32 = 0;
pub const EB_BUFFERFLAG_EOS: u32 = 0x0000_0001;
#[cfg(any(feature = "vship", test))]
pub const MAX_QP_VALUE: u32 = 63;
#[cfg(any(feature = "vship", test))]
pub const SVT_AV1_RC_MODE_CQP_OR_CRF: u8 = 0;

const MAX_TEMPORAL_LAYERS: usize = 6;
const FRAME_UPDATE_TYPES: usize = 7;

#[repr(C)]
pub struct EbComponentType {
    pub size: u32,
    pub p_component_private: *mut c_void,
    pub p_application_private: *mut c_void,
}

#[repr(C)]
pub struct EbBufferHeaderType {
    pub size: u32,
    pub p_buffer: *mut u8,
    pub n_filled_len: u32,
    pub n_alloc_len: u32,
    pub p_app_private: *mut c_void,
    pub wrapper_ptr: *mut c_void,
    pub n_tick_count: u32,
    pub dts: i64,
    pub pts: i64,
    #[cfg(not(feature = "5fish"))]
    pub temporal_layer_index: u8,
    pub qp: u32,
    #[cfg(not(feature = "5fish"))]
    pub avg_qp: u32,
    pub pic_type: u32,
    pub luma_sse: u64,
    pub cr_sse: u64,
    pub cb_sse: u64,
    pub flags: u32,
    pub luma_ssim: f64,
    pub cr_ssim: f64,
    pub cb_ssim: f64,
    pub metadata: *mut c_void,
}

// svt_drain.asm: layout change is a type error at compile time
const _: [(); 8] = [(); offset_of!(EbBufferHeaderType, p_buffer)];
const _: [(); 16] = [(); offset_of!(EbBufferHeaderType, n_filled_len)];
#[cfg(not(feature = "5fish"))]
const _: [(); 104] = [(); offset_of!(EbBufferHeaderType, flags)];
#[cfg(feature = "5fish")]
const _: [(); 96] = [(); offset_of!(EbBufferHeaderType, flags)];

#[repr(C)]
pub struct EbSvtIOFormat {
    pub luma: *mut u8,
    pub cb: *mut u8,
    pub cr: *mut u8,
    pub y_stride: u32,
    pub cr_stride: u32,
    pub cb_stride: u32,
}

#[repr(C)]
pub struct ChromaPoints {
    pub x: u16,
    pub y: u16,
}

#[repr(C)]
pub struct MasteringDisplayInfo {
    pub r: ChromaPoints,
    pub g: ChromaPoints,
    pub b: ChromaPoints,
    pub white_point: ChromaPoints,
    pub max_luma: u32,
    pub min_luma: u32,
}

#[repr(C)]
pub struct ContentLightLevel {
    pub max_cll: u16,
    pub max_fall: u16,
}

#[repr(C)]
struct FixedBuf {
    buf: *mut c_void,
    sz: u64,
}

#[repr(C)]
struct FrameScaleEvts {
    evt_num: u32,
    start_frame_nums: *mut u64,
    resize_kf_denoms: *mut u32,
    resize_denoms: *mut u32,
}

#[cfg(not(feature = "5fish"))]
#[repr(C)]
#[allow(clippy::struct_field_names)]
struct SFramePositions {
    sframe_num: u32,
    sframe_posis: *mut u64,
    sframe_qp_num: u32,
    sframe_qps: *mut u8,
    sframe_qp_offsets: *mut i8,
}

#[cfg(not(feature = "5fish"))]
#[repr(C)]
pub struct EbSvtAv1EncConfiguration {
    enc_mode: i8,
    pub intra_period_length: i32,
    #[cfg(feature = "svt-essential")]
    min_intra_period_length: i32,
    intra_refresh_type: i32,
    hierarchical_levels: u32,
    pred_structure: u8,
    pub source_width: u32,
    pub source_height: u32,
    forced_max_frame_width: u32,
    forced_max_frame_height: u32,
    pub frame_rate_numerator: u32,
    pub frame_rate_denominator: u32,
    pub encoder_bit_depth: u32,
    pub encoder_color_format: i32,
    pub profile: i32,
    tier: u32,
    level: u32,
    pub color_primaries: i32,
    pub transfer_characteristics: i32,
    pub matrix_coefficients: i32,
    pub color_range: i32,
    pub mastering_display: MasteringDisplayInfo,
    pub content_light_level: ContentLightLevel,
    pub chroma_sample_position: i32,
    pub rate_control_mode: u8,
    pub qp: u32,
    use_qp_file: bool,
    target_bit_rate: u32,
    max_bit_rate: u32,
    max_qp_allowed: u32,
    min_qp_allowed: u32,
    vbr_min_section_pct: u32,
    vbr_max_section_pct: u32,
    under_shoot_pct: u32,
    over_shoot_pct: u32,
    mbr_over_shoot_pct: u32,
    starting_buffer_level_ms: i64,
    optimal_buffer_level_ms: i64,
    maximum_buffer_size_ms: i64,
    rc_stats_buffer: FixedBuf,
    pass: i32,
    use_fixed_qindex_offsets: u8,
    qindex_offsets: [i32; MAX_TEMPORAL_LAYERS],
    key_frame_chroma_qindex_offset: i32,
    key_frame_qindex_offset: i32,
    chroma_qindex_offsets: [i32; MAX_TEMPORAL_LAYERS],
    luma_y_dc_qindex_offset: i32,
    chroma_u_dc_qindex_offset: i32,
    chroma_u_ac_qindex_offset: i32,
    chroma_v_dc_qindex_offset: i32,
    chroma_v_ac_qindex_offset: i32,
    enable_dlf_flag: u8,
    film_grain_denoise_strength: u32,
    film_grain_denoise_apply: u8,
    cdef_level: i32,
    enable_restoration_filtering: i32,
    enable_mfmv: i32,
    pub scene_change_detection: u32,
    tile_columns: i32,
    tile_rows: i32,
    look_ahead_distance: u32,
    recode_loop: u32,
    pub screen_content_mode: u32,
    pub aq_mode: u8,
    enable_tf: u8,
    enable_overlays: bool,
    tune: u8,
    superres_mode: u8,
    superres_denom: u8,
    superres_kf_denom: u8,
    superres_qthres: u8,
    superres_kf_qthres: u8,
    superres_auto_search_type: u8,
    fast_decode: u8,
    sframe_dist: i32,
    sframe_mode: i32,
    level_of_parallelism: u32,
    use_cpu_flags: u64,
    stat_report: u32,
    recon_enabled: bool,
    force_key_frames: bool,
    multiply_keyint: bool,
    resize_mode: u8,
    resize_denom: u8,
    resize_kf_denom: u8,
    enable_qm: bool,
    min_qm_level: u8,
    max_qm_level: u8,
    gop_constraint_rc: bool,
    lambda_scale_factors: [i32; FRAME_UPDATE_TYPES],
    enable_dg: bool,
    startup_mg_size: u8,
    startup_qp_offset: i8,
    frame_scale_evts: FrameScaleEvts,
    enable_roi_map: bool,
    tf_strength: u8,
    pub fgs_table: *mut c_void,
    enable_variance_boost: bool,
    variance_boost_strength: u8,
    variance_octile: u8,
    sharpness: i8,
    variance_boost_curve: u8,
    luminance_qp_bias: u8,
    lossless: bool,
    avif: bool,
    min_chroma_qm_level: u8,
    max_chroma_qm_level: u8,
    rtc: bool,
    qp_scale_compress_strength: u8,
    sframe_posi: SFramePositions,
    sframe_qp: u8,
    sframe_qp_offset: i8,
    adaptive_film_grain: bool,
    max_tx_size: u8,
    pub extended_crf_qindex_offset: u8,
    ac_bias: f64,
    _padding: [u8; 128],
}

#[cfg(feature = "5fish")]
#[repr(C)]
pub struct EbSvtAv1EncConfiguration {
    enc_mode: i8,
    pub intra_period_length: i32,
    min_intra_period_length: i32,
    intra_refresh_type: i32,
    hierarchical_levels: u32,
    pred_structure: u8,
    pub source_width: u32,
    pub source_height: u32,
    forced_max_frame_width: u32,
    forced_max_frame_height: u32,
    pub frame_rate_numerator: u32,
    pub frame_rate_denominator: u32,
    pub encoder_bit_depth: u32,
    pub encoder_color_format: i32,
    high_dynamic_range_input: u8,
    pub profile: i32,
    tier: u32,
    level: u32,
    color_description_present_flag: bool,
    pub color_primaries: i32,
    pub transfer_characteristics: i32,
    pub matrix_coefficients: i32,
    pub color_range: i32,
    pub mastering_display: MasteringDisplayInfo,
    pub content_light_level: ContentLightLevel,
    pub chroma_sample_position: i32,
    pub rate_control_mode: u32,
    pub qp: u32,
    use_qp_file: bool,
    target_bit_rate: u32,
    max_bit_rate: u32,
    max_qp_allowed: u32,
    min_qp_allowed: u32,
    vbr_min_section_pct: u32,
    vbr_max_section_pct: u32,
    under_shoot_pct: u32,
    over_shoot_pct: u32,
    mbr_over_shoot_pct: u32,
    starting_buffer_level_ms: i64,
    optimal_buffer_level_ms: i64,
    maximum_buffer_size_ms: i64,
    rc_stats_buffer: FixedBuf,
    pass: i32,
    use_fixed_qindex_offsets: u8,
    qindex_offsets: [i32; MAX_TEMPORAL_LAYERS],
    key_frame_chroma_qindex_offset: i32,
    key_frame_qindex_offset: i32,
    chroma_qindex_offsets: [i32; MAX_TEMPORAL_LAYERS],
    luma_y_dc_qindex_offset: i32,
    chroma_u_dc_qindex_offset: i32,
    chroma_u_ac_qindex_offset: i32,
    chroma_v_dc_qindex_offset: i32,
    chroma_v_ac_qindex_offset: i32,
    enable_dlf_flag: u8,
    film_grain_denoise_strength: u32,
    film_grain_denoise_apply: u8,
    cdef_level: i32,
    enable_restoration_filtering: i32,
    enable_mfmv: i32,
    pub scene_change_detection: u32,
    restricted_motion_vector: bool,
    tile_columns: i32,
    tile_rows: i32,
    look_ahead_distance: u32,
    enable_tpl_la: u8,
    recode_loop: u32,
    pub screen_content_mode: u32,
    pub enable_adaptive_quantization: u8,
    enable_tf: u8,
    enable_overlays: bool,
    tune: u8,
    superres_mode: u8,
    superres_denom: u8,
    superres_kf_denom: u8,
    superres_qthres: u8,
    superres_kf_qthres: u8,
    superres_auto_search_type: u8,
    fast_decode: u8,
    sframe_dist: i32,
    sframe_mode: i32,
    channel_id: u32,
    active_channel_count: u32,
    level_of_parallelism: u32,
    pin_threads: u32,
    target_socket: i32,
    use_cpu_flags: u64,
    stat_report: u32,
    recon_enabled: bool,
    force_key_frames: bool,
    resize_mode: u8,
    resize_denom: u8,
    resize_kf_denom: u8,
    enable_qm: bool,
    min_qm_level: u8,
    max_qm_level: u8,
    min_chroma_qm_level: u8,
    max_chroma_qm_level: u8,
    gop_constraint_rc: bool,
    lambda_scale_factors: [i32; FRAME_UPDATE_TYPES],
    enable_dg: bool,
    startup_mg_size: u8,
    frame_scale_evts: FrameScaleEvts,
    enable_roi_map: bool,
    pub fgs_table: *mut c_void,
    enable_variance_boost: u8,
    variance_boost_strength: u8,
    variance_octile: u8,
    enable_alt_curve: bool,
    sharpness: i8,
    pub extended_crf_qindex_offset: u8,
    double_crf: f64,
    qp_scale_compress_strength: f64,
    frame_luma_bias: u8,
    luminance_qp_bias: u8,
    max_32_tx_size: bool,
    adaptive_film_grain: bool,
    tf_strength: u8,
    kf_tf_strength: u8,
    noise_norm_strength: u8,
    ac_bias: f64,
    texture_ac_bias: f64,
    lineart_energy_bias: f64,
    texture_energy_bias: f64,
    satd_bias: f64,
    tx_bias: u8,
    low_q_taper: bool,
    noise_level_thr: i32,
    lineart_psy_bias: f64,
    texture_psy_bias: f64,
    noise_psy_bias: f64,
    lineart_psy_bias_easter_egg: i8,
    texture_psy_bias_easter_egg: i8,
    lineart_variance_thr: u16,
    texture_variance_thr: u16,
    psy_bias_mds0_sad: u8,
    psy_bias_disable_warped_motion: u8,
    psy_bias_disable_me_8x8: u8,
    psy_bias_disable_sgrproj: u8,
    psy_bias_coeff_lvl_offset: i8,
    psy_bias_mds0_intra_inter_mode_bias: u8,
    psy_bias_inter_mode_bias: u8,
    psy_bias_qm_bias: u8,
    psy_bias_sharpness_rounding: i32,
    psy_bias_optimize_b: i8,
    texture_psy_bias_optimize_b: i8,
    high_quality_encode_psy_bias: f64,
    high_fidelity_encode_psy_bias: f64,
    dlf_bias: u8,
    dlf_sharpness: u8,
    dlf_bias_max_dlf: [u8; 2],
    dlf_bias_min_dlf: [u8; 2],
    cdef_bias: u8,
    cdef_bias_max_cdef: [u8; 4],
    cdef_bias_min_cdef: [u8; 4],
    cdef_bias_max_sec_cdef_rel: i8,
    texture_cdef_bias_max_cdef: [u8; 4],
    texture_cdef_bias_min_cdef: [u8; 4],
    texture_cdef_bias_max_sec_cdef_rel: i8,
    cdef_bias_damping_offset: i8,
    balancing_q_bias: u8,
    balancing_luminance_q_bias: u8,
    balancing_noise_level_q_bias: f64,
    balancing_luminance_lambda_bias: f64,
    balancing_texture_lambda_bias: f64,
    balancing_r0_dampening_layer: i8,
    balancing_tpl_intra_mode_beta_bias: u8,
    sharp_tx: bool,
    hbd_mds: u8,
    alt_ssim_tuning: bool,
    filtering_noise_detection: u8,
    auto_tiling: bool,
    photon_noise_iso: u32,
    enable_photon_noise_chroma: u8,
    static_fgs_seed: i32,
    color_range_provided: bool,
    chroma_grain: bool,
    alt_tf_decay: bool,
    _padding: [u8; 128],
}

#[cfg(feature = "5fish")]
const _: [(); 92] = [(); offset_of!(EbSvtAv1EncConfiguration, mastering_display)];
#[cfg(feature = "5fish")]
const _: [(); 116] = [(); offset_of!(EbSvtAv1EncConfiguration, content_light_level)];
#[cfg(feature = "5fish")]
const _: [(); 124] = [(); offset_of!(EbSvtAv1EncConfiguration, rate_control_mode)];
#[cfg(feature = "5fish")]
const _: [(); 456] = [(); offset_of!(EbSvtAv1EncConfiguration, frame_scale_evts)];
#[cfg(feature = "5fish")]
const _: [(); 496] = [(); offset_of!(EbSvtAv1EncConfiguration, fgs_table)];
#[cfg(feature = "5fish")]
const _: [(); 536] = [(); offset_of!(EbSvtAv1EncConfiguration, ac_bias)];
#[cfg(feature = "5fish")]
const _: [(); 726] = [(); offset_of!(EbSvtAv1EncConfiguration, alt_tf_decay)];
#[cfg(feature = "5fish")]
const _: () = assert!(size_of::<EbSvtAv1EncConfiguration>() >= 728);

#[link(name = "SvtAv1Enc")]
unsafe extern "C" {
    #[cfg(feature = "5fish")]
    pub fn svt_av1_enc_init_handle(
        p_handle: *mut *mut EbComponentType,
        p_app_data: *mut c_void,
        config_ptr: *mut EbSvtAv1EncConfiguration,
    ) -> i32;

    #[cfg(not(feature = "5fish"))]
    pub fn svt_av1_enc_init_handle(
        p_handle: *mut *mut EbComponentType,
        conf_ptr: *mut EbSvtAv1EncConfiguration,
    ) -> i32;

    pub fn svt_av1_enc_set_parameter(
        svt_enc_component: *mut EbComponentType,
        conf: *mut EbSvtAv1EncConfiguration,
    ) -> i32;

    pub fn svt_av1_enc_parse_parameter(
        conf: *mut EbSvtAv1EncConfiguration,
        name: *const i8,
        value: *const i8,
    ) -> i32;

    pub fn svt_av1_enc_init(svt_enc_component: *mut EbComponentType) -> i32;

    pub fn svt_av1_enc_send_picture(
        svt_enc_component: *mut EbComponentType,
        p_buffer: *mut EbBufferHeaderType,
    ) -> i32;

    pub fn svt_av1_enc_deinit(svt_enc_component: *mut EbComponentType) -> i32;

    pub fn svt_av1_enc_deinit_handle(svt_enc_component: *mut EbComponentType) -> i32;
}
