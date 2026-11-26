//! What macOS and iOS share: Apple's decoders for AV1 and VP9.

use std::{
    ffi::{c_char, c_void},
    sync::Once,
};

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
}

/// Lets VideoToolbox decode AV1 and VP9 where the system has decoders for them (AV1 in
/// hardware on M3, A17 Pro and later), which it offers only to apps that ask. Looked up by
/// name: the function is new (macOS 11, iOS 26.2).
pub(crate) fn offer_supplemental_decoders() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        /// `RTLD_DEFAULT`: every image loaded.
        const DEFAULT: *mut c_void = -2_isize as *mut c_void;
        // SAFETY: looks up a VideoToolbox function by its NUL-terminated name.
        let found = unsafe { dlsym(DEFAULT, c"VTRegisterSupplementalVideoDecoderIfAvailable".as_ptr()) };
        if found.is_null() {
            return;
        }
        // SAFETY: the function's type: `void (CMVideoCodecType)`.
        let register: unsafe extern "C" fn(u32) = unsafe { std::mem::transmute(found) };
        for codec in [*b"av01", *b"vp09"] {
            // SAFETY: a four-character codec type, as the function takes.
            unsafe { register(u32::from_be_bytes(codec)) };
        }
    });
}
