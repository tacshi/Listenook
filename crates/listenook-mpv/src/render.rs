//! mpv drawing into frames the app gives it (`vo=libmpv`, `mpv/render.h`), with OpenGL or
//! Direct3D 11, at whatever size they are.

use std::{
    ffi::{c_char, c_int, c_void},
    ptr::{self, NonNull},
};

use crate::mpv::{Mpv, c, checked};

#[repr(C)]
struct RenderParam {
    kind: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct OpenGlInit {
    get_proc_address: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void,
    get_proc_address_ctx: *mut c_void,
}

#[repr(C)]
struct OpenGlFbo {
    fbo: c_int,
    w: c_int,
    h: c_int,
    internal_format: c_int,
}

const PARAM_API_TYPE: c_int = 1;
const PARAM_OPENGL_INIT_PARAMS: c_int = 2;
const PARAM_OPENGL_FBO: c_int = 3;
const PARAM_FLIP_Y: c_int = 4;
const PARAM_BLOCK_FOR_TARGET_TIME: c_int = 12;
const UPDATE_FRAME: u64 = 1;

#[cfg_attr(windows, link(name = "libmpv-2", kind = "raw-dylib"))]
unsafe extern "C" {
    fn mpv_render_context_create(out: *mut *mut c_void, mpv: *mut c_void, params: *mut RenderParam) -> c_int;
    fn mpv_render_context_set_update_callback(
        ctx: *mut c_void,
        callback: Option<unsafe extern "C" fn(*mut c_void)>,
        callback_ctx: *mut c_void,
    );
    fn mpv_render_context_update(ctx: *mut c_void) -> u64;
    fn mpv_render_context_render(ctx: *mut c_void, params: *mut RenderParam) -> c_int;
    fn mpv_render_context_report_swap(ctx: *mut c_void);
    fn mpv_render_context_free(ctx: *mut c_void);
}

/// Something to call when mpv has a new frame to draw (from mpv's threads).
pub(crate) type OnFrame = Box<dyn Fn() + Send + Sync>;

/// mpv drawing with OpenGL into frames the app gives it (`vo=libmpv`), at whatever size they
/// are. Made, used and dropped with the OpenGL context current, one thread at a time; it keeps
/// mpv running until it goes.
pub(crate) struct Render {
    context: NonNull<c_void>,
    _mpv: std::sync::Arc<Mpv>,
    _on_frame: Box<OnFrame>,
}

// SAFETY: the render API may be used from any thread, one call at a time, which the owner
// ensures (`Mutex`).
unsafe impl Send for Render {}

unsafe extern "C" fn frame_ready(ctx: *mut c_void) {
    // SAFETY: `ctx` is the `OnFrame` box the render context was given, alive until it is freed.
    unsafe { (*ctx.cast::<OnFrame>())() }
}

/// How mpv draws.
pub(crate) enum Api {
    /// With the OpenGL (ES) context current when the renderer is made and used, finding its
    /// functions with the function given.
    OpenGl(unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void),
    /// With this `ID3D11Device`, into textures the app gives it.
    #[cfg_attr(not(windows), allow(dead_code))]
    Direct3D11(*mut c_void),
}

#[repr(C)]
struct D3d11Init {
    device: *mut c_void,
}

#[repr(C)]
struct D3d11Target {
    texture: *mut c_void,
}

const PARAM_D3D11_INIT_PARAMS: c_int = 21;
const PARAM_D3D11_FBO: c_int = 22;

impl Render {
    /// Draws for `mpv` with `api`; `on_frame` is called whenever there is something new to draw.
    pub(crate) fn new(mpv: &std::sync::Arc<Mpv>, api: Api, on_frame: OnFrame) -> Result<Self, String> {
        let (mut gl, mut d3d);
        let (kind, init) = match api {
            Api::OpenGl(get_proc_address) => {
                gl = OpenGlInit { get_proc_address, get_proc_address_ctx: ptr::null_mut() };
                ("opengl", RenderParam { kind: PARAM_OPENGL_INIT_PARAMS, data: (&raw mut gl).cast() })
            }
            Api::Direct3D11(device) => {
                d3d = D3d11Init { device };
                ("d3d11", RenderParam { kind: PARAM_D3D11_INIT_PARAMS, data: (&raw mut d3d).cast() })
            }
        };
        let api = c(kind);
        let mut block: c_int = 0;
        let mut params = [
            RenderParam { kind: PARAM_API_TYPE, data: api.as_ptr().cast_mut().cast() },
            init,
            RenderParam { kind: PARAM_BLOCK_FOR_TARGET_TIME, data: (&raw mut block).cast() },
            RenderParam { kind: 0, data: ptr::null_mut() },
        ];
        let mut context = ptr::null_mut();
        // SAFETY: the parameters live through the call; an OpenGL context is current.
        checked(unsafe { mpv_render_context_create(&raw mut context, mpv.raw(), params.as_mut_ptr()) })?;
        let context = NonNull::new(context).ok_or("mpv made no render context")?;
        let mut on_frame = Box::new(on_frame);
        // SAFETY: the box stays at this address until the context is freed, in `drop`.
        unsafe {
            mpv_render_context_set_update_callback(context.as_ptr(), Some(frame_ready), (&raw mut *on_frame).cast());
        }
        Ok(Render { context, _mpv: mpv.clone(), _on_frame: on_frame })
    }

    /// Whether a new frame waits to be drawn (after `on_frame` was called).
    pub(crate) fn has_frame(&self) -> bool {
        // SAFETY: a live render context.
        unsafe { mpv_render_context_update(self.context.as_ptr()) & UPDATE_FRAME != 0 }
    }

    /// Draws the current frame into framebuffer `fbo`, `width` × `height` pixels, upside down
    /// for OpenGL's own framebuffers (`flip`).
    pub(crate) fn draw(&self, fbo: i32, width: i32, height: i32, flip: bool) {
        let mut target = OpenGlFbo { fbo, w: width, h: height, internal_format: 0 };
        let mut flip = c_int::from(flip);
        let mut params = [
            RenderParam { kind: PARAM_OPENGL_FBO, data: (&raw mut target).cast() },
            RenderParam { kind: PARAM_FLIP_Y, data: (&raw mut flip).cast() },
            RenderParam { kind: 0, data: ptr::null_mut() },
        ];
        // SAFETY: the parameters live through the call; the OpenGL context is current.
        if let Err(why) = checked(unsafe { mpv_render_context_render(self.context.as_ptr(), params.as_mut_ptr()) }) {
            log::warn!("mpv could not draw: {why}");
        }
    }

    /// Draws the current frame into `texture`, an `ID3D11Texture2D` it may render to.
    #[cfg_attr(not(windows), allow(dead_code))]
    pub(crate) fn draw_texture(&self, texture: *mut c_void) {
        let mut target = D3d11Target { texture };
        let mut params = [
            RenderParam { kind: PARAM_D3D11_FBO, data: (&raw mut target).cast() },
            RenderParam { kind: 0, data: ptr::null_mut() },
        ];
        // SAFETY: the parameters live through the call; the texture is the caller's.
        if let Err(why) = checked(unsafe { mpv_render_context_render(self.context.as_ptr(), params.as_mut_ptr()) }) {
            log::warn!("mpv could not draw: {why}");
        }
    }

    /// The frame drawn last is on screen.
    pub(crate) fn shown(&self) {
        // SAFETY: a live render context.
        unsafe { mpv_render_context_report_swap(self.context.as_ptr()) }
    }
}

impl Drop for Render {
    fn drop(&mut self) {
        // SAFETY: freed once, with the OpenGL context current; `on_frame` goes after.
        unsafe { mpv_render_context_free(self.context.as_ptr()) }
    }
}
