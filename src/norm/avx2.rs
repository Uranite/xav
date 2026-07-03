unsafe extern "C" {
    fn xav_mix6(src: *const f32, dst: *mut f32, n: usize);
    fn xav_mix7(src: *const f32, dst: *mut f32, n: usize);
    fn xav_mix8(src: *const f32, dst: *mut f32, n: usize);
    fn xav_loud(src: *const f32, n: usize, stride: usize, st: *mut f64, out: *mut f64);
}

#[inline(always)]
fn mix6(src: &[f32], dst: &mut [f32], n: usize) {
    unsafe { xav_mix6(src.as_ptr(), dst.as_mut_ptr(), n) };
}

#[inline(always)]
fn mix7(src: &[f32], dst: &mut [f32], n: usize) {
    unsafe { xav_mix7(src.as_ptr(), dst.as_mut_ptr(), n) };
}

#[inline(always)]
fn mix8(src: &[f32], dst: &mut [f32], n: usize) {
    unsafe { xav_mix8(src.as_ptr(), dst.as_mut_ptr(), n) };
}
