//! On Linux, mpv draws with OpenGL into a `GtkGLArea`, a frame at a time as the frame clock
//! finds one ready, at the area's size of the moment.

use std::{
    cell::RefCell,
    ffi::{CString, c_char, c_int, c_void},
    rc::Rc,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
};

use nsh_platform_linux::{ComponentContext, NativeComponent, gtk4 as gtk};
use serde_json::Value as JsonValue;

use gtk::{glib, prelude::*};

use crate::{
    player::{Emit, Player, Screen},
    render::{Api, Render},
};

unsafe extern "C" {
    fn dlopen(name: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
}

const RTLD_LAZY: c_int = 1;
const GL_DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;

type GetProcAddress = unsafe extern "C" fn(*const c_char) -> *mut c_void;

/// The loader of OpenGL functions of the context GTK made: EGL's (GTK's default, X11 and
/// Wayland alike), or GLX's.
fn loader() -> Option<GetProcAddress> {
    static LOADER: OnceLock<Option<GetProcAddress>> = OnceLock::new();
    *LOADER.get_or_init(|| {
        [("libEGL.so.1", "eglGetProcAddress"), ("libGL.so.1", "glXGetProcAddressARB")].into_iter().find_map(
            |(library, function)| {
                let (library, function) = (CString::new(library).ok()?, CString::new(function).ok()?);
                // SAFETY: loads a system library already in the process (GTK's), and looks up a
                // function of the `GetProcAddress` type in it.
                unsafe {
                    let handle = dlopen(library.as_ptr(), RTLD_LAZY);
                    let found =
                        (!handle.is_null()).then(|| dlsym(handle, function.as_ptr())).filter(|f| !f.is_null())?;
                    Some(std::mem::transmute::<*mut c_void, GetProcAddress>(found))
                }
            },
        )
    })
}

/// OpenGL's functions, for mpv.
unsafe extern "C" fn proc_address(_ctx: *mut c_void, name: *const c_char) -> *mut c_void {
    // SAFETY: `name` is a NUL-terminated function name.
    loader().map_or(std::ptr::null_mut(), |load| unsafe { load(name) })
}

/// The framebuffer GTK has the area draw into now.
fn framebuffer() -> i32 {
    let name = c"glGetIntegerv";
    // SAFETY: `glGetIntegerv`, from the current context, writes one integer for this name.
    unsafe {
        let function = proc_address(std::ptr::null_mut(), name.as_ptr());
        if function.is_null() {
            return 0;
        }
        let get: unsafe extern "C" fn(u32, *mut i32) = std::mem::transmute(function);
        let mut fbo = 0;
        get(GL_DRAW_FRAMEBUFFER_BINDING, &raw mut fbo);
        fbo
    }
}

pub(crate) struct Video {
    area: gtk::GLArea,
    render: Rc<RefCell<Option<Render>>>,
    player: Player,
}

impl Video {
    pub(crate) fn make(cx: ComponentContext) -> Box<dyn NativeComponent> {
        let emit: Emit = Arc::new(move |name, data| cx.emit(name, data));
        let screen =
            // No video output until GTK has made the OpenGL context mpv draws with (`render`).
            Screen { options: vec![("vo", "null".into())], wid: None, keep: Box::new(()), before_playing: None };
        let player = Player::new(screen, emit);
        let area = gtk::GLArea::new();
        area.set_auto_render(false);
        area.set_has_depth_buffer(false);
        area.set_has_stencil_buffer(false);
        // Clicks go through it to what the app put under or around it.
        area.set_can_target(false);
        let render: Rc<RefCell<Option<Render>>> = Rc::default();
        let dirty = Arc::new(AtomicBool::new(true));
        let (output, made, ready) = (player.output(), render.clone(), dirty.clone());
        area.connect_realize(move |area| {
            area.make_current();
            if let Some(error) = area.error() {
                log::error!("no OpenGL context for mpv: {error}");
                return;
            }
            let ready = ready.clone();
            match output.render(Api::OpenGl(proc_address), Box::new(move || ready.store(true, Ordering::Release))) {
                Ok(render) => *made.borrow_mut() = Some(render),
                Err(why) => log::error!("mpv cannot draw with OpenGL: {why}"),
            }
        });
        let gone = render.clone();
        area.connect_unrealize(move |area| {
            area.make_current();
            gone.borrow_mut().take();
        });
        let (drawn, ticking) = (render.clone(), render.clone());
        area.connect_render(move |area, _| {
            if let Some(render) = drawn.borrow().as_ref() {
                let scale = area.scale_factor();
                render.draw(framebuffer(), area.width() * scale, area.height() * scale, true);
                render.shown();
            }
            glib::Propagation::Stop
        });
        area.connect_resize(|area, _, _| area.queue_render());
        area.add_tick_callback(move |area, _| {
            let new = dirty.swap(false, Ordering::AcqRel);
            if ticking.borrow().as_ref().is_some_and(|render| render.has_frame() || new) {
                area.queue_render();
            }
            glib::ControlFlow::Continue
        });
        Box::new(Video { area, render, player })
    }
}

impl NativeComponent for Video {
    fn widget(&self) -> gtk::Widget {
        self.area.clone().upcast()
    }

    fn set_prop(&mut self, name: &str, value: Option<&JsonValue>) {
        self.player.set_prop(name, value);
    }

    fn command(&mut self, name: &str, args: &JsonValue) {
        self.player.command(name, args);
    }
}

impl Drop for Video {
    /// mpv stops drawing, with the area's OpenGL context current, before the player stops it.
    fn drop(&mut self) {
        if let Some(render) = self.render.borrow_mut().take() {
            self.area.make_current();
            drop(render);
        }
    }
}
