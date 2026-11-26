//! On macOS, mpv draws with OpenGL into a `CAOpenGLLayer`, as IINA does: each frame is drawn at
//! the layer's size of the moment, so the picture follows the view as it resizes, and is
//! clipped, rounded and covered like anything else nsh shows.

// Apple deprecated OpenGL but still ships it; mpv's render API has no Metal backend.
#![allow(deprecated)]

use std::{
    ffi::{c_char, c_void},
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

use nsh_platform_macos::{ComponentContext, NativeComponent};
use objc2::{
    AllocAnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained, runtime::Bool,
};
use objc2_app_kit::{NSResponder, NSView};
use objc2_core_video::CVTimeStamp;
use objc2_foundation::{NSObject, NSPoint, NSSize};
use objc2_open_gl::{CGLContextObj, CGLPixelFormatObj};
use objc2_quartz_core::{CALayer, CAOpenGLLayer, CATransaction};
use serde_json::Value as JsonValue;

use crate::{
    player::{Emit, Player, Screen},
    render::{Api, Render},
};

#[link(name = "OpenGL", kind = "framework")]
unsafe extern "C" {
    fn CGLChoosePixelFormat(attributes: *const i32, format: *mut CGLPixelFormatObj, count: *mut i32) -> i32;
    fn CGLCreateContext(format: CGLPixelFormatObj, share: CGLContextObj, context: *mut CGLContextObj) -> i32;
    fn CGLRetainContext(context: CGLContextObj) -> CGLContextObj;
    fn CGLReleaseContext(context: CGLContextObj);
    fn CGLRetainPixelFormat(format: CGLPixelFormatObj) -> CGLPixelFormatObj;
    fn CGLReleasePixelFormat(format: CGLPixelFormatObj);
    fn CGLSetCurrentContext(context: CGLContextObj) -> i32;
    fn CGLLockContext(context: CGLContextObj) -> i32;
    fn CGLUnlockContext(context: CGLContextObj) -> i32;
    fn glGetIntegerv(name: u32, out: *mut i32);
}

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
}

const GL_VIEWPORT: u32 = 0x0BA2;
const GL_DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;

/// OpenGL's functions, for mpv: the framework is linked in.
unsafe extern "C" fn proc_address(_ctx: *mut c_void, name: *const c_char) -> *mut c_void {
    /// `RTLD_DEFAULT`: every image loaded.
    const DEFAULT: *mut c_void = -2_isize as *mut c_void;
    // SAFETY: `name` is a NUL-terminated symbol name.
    unsafe { dlsym(DEFAULT, name) }
}

/// The OpenGL 3.2 context mpv draws with, and its pixel format, released when dropped.
struct Gl {
    format: CGLPixelFormatObj,
    context: CGLContextObj,
}

// SAFETY: CGL objects are reference-counted and usable from any thread, one at a time
// (`CGLLockContext`).
unsafe impl Send for Gl {}
// SAFETY: as above.
unsafe impl Sync for Gl {}

impl Gl {
    fn new() -> Option<Gl> {
        const DOUBLE_BUFFER: i32 = 5;
        const ACCELERATED: i32 = 73;
        const OFFLINE_RENDERERS: i32 = 96;
        const PROFILE: i32 = 99;
        const GRAPHICS_SWITCHING: i32 = 101;
        const CORE_3_2: i32 = 0x3200;
        let attributes = [PROFILE, CORE_3_2, ACCELERATED, DOUBLE_BUFFER, OFFLINE_RENDERERS, GRAPHICS_SWITCHING, 0];
        let (mut format, mut count, mut context) = (ptr::null_mut(), 0, ptr::null_mut());
        // SAFETY: a zero-terminated attribute list; the outputs are written.
        unsafe {
            if CGLChoosePixelFormat(attributes.as_ptr(), &raw mut format, &raw mut count) != 0 || format.is_null() {
                return None;
            }
            if CGLCreateContext(format, ptr::null_mut(), &raw mut context) != 0 || context.is_null() {
                CGLReleasePixelFormat(format);
                return None;
            }
        }
        Some(Gl { format, context })
    }

    /// Runs `f` with the context locked and current on this thread.
    fn with<T>(&self, f: impl FnOnce() -> T) -> T {
        // SAFETY: a live context; the lock keeps CoreAnimation from drawing with it meanwhile.
        unsafe {
            CGLLockContext(self.context);
            CGLSetCurrentContext(self.context);
        }
        let out = f();
        // SAFETY: as above.
        unsafe {
            CGLSetCurrentContext(ptr::null_mut());
            CGLUnlockContext(self.context);
        }
        out
    }
}

impl Drop for Gl {
    fn drop(&mut self) {
        // SAFETY: the references taken in `new`.
        unsafe {
            CGLReleaseContext(self.context);
            CGLReleasePixelFormat(self.format);
        }
    }
}

struct LayerState {
    gl: Gl,
    render: Mutex<Option<Render>>,
    /// mpv has a new frame, or the layer changed size: draw at the next display.
    dirty: Arc<AtomicBool>,
}

impl LayerState {
    fn render(&self) -> std::sync::MutexGuard<'_, Option<Render>> {
        self.render.lock().unwrap_or_else(|e| e.into_inner())
    }
}

define_class!(
    /// The layer mpv draws in. CoreAnimation asks it at each display, on its own thread,
    /// whether there is anything new, and has it draw then.
    #[unsafe(super(CAOpenGLLayer, CALayer, NSObject))]
    #[name = "ListenookMpvLayer"]
    #[ivars = LayerState]
    struct MpvLayer;

    impl MpvLayer {
        #[unsafe(method(copyCGLPixelFormatForDisplayMask:))]
        fn pixel_format(&self, _mask: u32) -> CGLPixelFormatObj {
            // SAFETY: the caller takes this reference.
            unsafe { CGLRetainPixelFormat(self.ivars().gl.format) }
        }

        #[unsafe(method(copyCGLContextForPixelFormat:))]
        fn context(&self, _format: CGLPixelFormatObj) -> CGLContextObj {
            // SAFETY: the caller takes this reference.
            unsafe { CGLRetainContext(self.ivars().gl.context) }
        }

        #[unsafe(method(canDrawInCGLContext:pixelFormat:forLayerTime:displayTime:))]
        fn can_draw(
            &self,
            _context: CGLContextObj,
            _format: CGLPixelFormatObj,
            _time: f64,
            _display: *const CVTimeStamp,
        ) -> Bool {
            let state = self.ivars();
            let dirty = state.dirty.swap(false, Ordering::AcqRel);
            Bool::new(state.render().as_ref().is_some_and(|render| render.has_frame() || dirty))
        }

        #[unsafe(method(drawInCGLContext:pixelFormat:forLayerTime:displayTime:))]
        fn draw(&self, context: CGLContextObj, format: CGLPixelFormatObj, time: f64, display: *const CVTimeStamp) {
            let state = self.ivars();
            if let Some(render) = state.render().as_ref() {
                let (mut viewport, mut fbo) = ([0_i32; 4], 0_i32);
                // SAFETY: CoreAnimation made `context` current, with the viewport at the size of
                // the drawable; each call writes what it is given.
                unsafe {
                    glGetIntegerv(GL_VIEWPORT, viewport.as_mut_ptr());
                    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &raw mut fbo);
                }
                render.draw(fbo, viewport[2], viewport[3], true);
            }
            // SAFETY: CAOpenGLLayer's own implementation, which flushes what was drawn.
            let _: () = unsafe {
                msg_send![super(self), drawInCGLContext: context, pixelFormat: format, forLayerTime: time, displayTime: display]
            };
            if let Some(render) = state.render().as_ref() {
                render.shown();
            }
        }
    }
);

impl MpvLayer {
    fn new(gl: Gl) -> Retained<Self> {
        let state = LayerState { gl, render: Mutex::new(None), dirty: Arc::new(AtomicBool::new(true)) };
        let this = Self::alloc().set_ivars(state);
        // SAFETY: CALayer's designated initializer.
        let this: Retained<Self> = unsafe { msg_send![super(this), init] };
        this.setAsynchronous(true);
        // Its drawable follows its size only when it is told to display again.
        this.setNeedsDisplayOnBoundsChange(true);
        this.setOpaque(false);
        this
    }

    /// Has mpv draw into this layer from now on.
    fn attach(&self, player: &Player) {
        let state = self.ivars();
        let (output, dirty) = (player.output(), state.dirty.clone());
        let made = state
            .gl
            .with(|| output.render(Api::OpenGl(proc_address), Box::new(move || dirty.store(true, Ordering::Release))));
        match made {
            Ok(render) => *state.render() = Some(render),
            Err(why) => log::error!("mpv cannot draw with OpenGL: {why}"),
        }
    }

    /// Stops mpv drawing here; mpv requires it before it stops itself.
    fn detach(&self) {
        let state = self.ivars();
        let render = state.render().take();
        if let Some(render) = render {
            state.gl.with(move || drop(render));
        }
    }
}

define_class!(
    /// The view holding the layer, sized to it. Clicks go through it to what the app put under
    /// or around it.
    #[unsafe(super(NSView, NSResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "ListenookMpvView"]
    #[ivars = Option<Retained<MpvLayer>>]
    struct MpvView;

    impl MpvView {
        #[unsafe(method(hitTest:))]
        fn hit_test(&self, _point: NSPoint) -> *mut NSView {
            ptr::null_mut()
        }

        #[unsafe(method(setFrameSize:))]
        fn set_frame_size(&self, size: NSSize) {
            // SAFETY: NSView's own implementation, with the same argument.
            let _: () = unsafe { msg_send![super(self), setFrameSize: size] };
            self.fit();
        }

        #[unsafe(method(viewDidMoveToWindow))]
        fn moved_to_window(&self) {
            // SAFETY: NSView's own implementation.
            let _: () = unsafe { msg_send![super(self), viewDidMoveToWindow] };
            self.fit();
        }

        #[unsafe(method(viewDidChangeBackingProperties))]
        fn backing_changed(&self) {
            // SAFETY: NSView's own implementation.
            let _: () = unsafe { msg_send![super(self), viewDidChangeBackingProperties] };
            self.fit();
        }
    }
);

impl MpvView {
    fn new(mtm: MainThreadMarker, layer: Option<Retained<MpvLayer>>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(layer);
        // SAFETY: NSView's designated initializer for a view laid out by its parent.
        let this: Retained<Self> = unsafe { msg_send![super(this), init] };
        this.setWantsLayer(true);
        if let (Some(root), Some(layer)) = (this.layer(), this.ivars()) {
            root.addSublayer(layer);
        }
        this
    }

    /// Sizes the layer to the view, in the screen's pixels.
    fn fit(&self) {
        let Some(layer) = self.ivars() else { return };
        let scale = self.window().map_or(2.0, |window| window.backingScaleFactor());
        CATransaction::begin();
        CATransaction::setDisableActions(true);
        layer.setFrame(self.bounds());
        layer.setContentsScale(scale);
        layer.setNeedsDisplay();
        CATransaction::commit();
        layer.ivars().dirty.store(true, Ordering::Release);
    }

    /// Keeps its window's content at the shape of `size` (width, height) as it is resized;
    /// `None` lets it take any shape again.
    fn keep_window_shape(&self, size: Option<(f64, f64)>) {
        let Some(window) = self.window() else { return };
        match size {
            Some((width, height)) if width > 0.0 && height > 0.0 => {
                window.setContentAspectRatio(NSSize::new(width, height));
            }
            // Resize increments and an aspect ratio replace each other.
            _ => window.setContentResizeIncrements(NSSize::new(1.0, 1.0)),
        }
    }
}

pub(crate) struct Video {
    view: Retained<MpvView>,
    player: Player,
}

impl Video {
    pub(crate) fn make(cx: ComponentContext) -> Box<dyn NativeComponent> {
        let mtm = MainThreadMarker::new().expect("nsh makes components on the main thread");
        crate::apple::offer_supplemental_decoders();
        let emit: Emit = Arc::new(move |name, data| cx.emit(name, data));
        let screen =
            Screen { options: vec![("vo", "libmpv".into())], wid: None, keep: Box::new(()), before_playing: None };
        let player = Player::new(screen, emit);
        let layer = match Gl::new() {
            Some(gl) => {
                let layer = MpvLayer::new(gl);
                layer.attach(&player);
                Some(layer)
            }
            None => {
                log::error!("no OpenGL context for mpv: videos play without their picture");
                None
            }
        };
        Box::new(Video { view: MpvView::new(mtm, layer), player })
    }
}

impl NativeComponent for Video {
    fn view(&self) -> Retained<NSView> {
        Retained::into_super(self.view.clone())
    }

    fn set_prop(&mut self, name: &str, value: Option<&JsonValue>) {
        if name == "windowShape" {
            let size = value
                .and_then(JsonValue::as_array)
                .and_then(|pair| Some((pair.first()?.as_f64()?, pair.get(1)?.as_f64()?)));
            self.view.keep_window_shape(size);
            return;
        }
        self.player.set_prop(name, value);
    }

    fn command(&mut self, name: &str, args: &JsonValue) {
        self.player.command(name, args);
    }
}

impl Drop for Video {
    /// mpv stops drawing before the player stops it.
    fn drop(&mut self) {
        if let Some(layer) = self.view.ivars() {
            layer.detach();
        }
    }
}
