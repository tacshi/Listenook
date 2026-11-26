//! On Windows, mpv draws with Direct3D 11 into a composition swap chain, the content of a
//! DirectComposition visual that nsh stacks with what it draws: the picture is placed, clipped,
//! rounded and covered like the rest of the window. Frames are drawn on a thread of their own
//! as mpv has them, and at once at each new size of the view, which the window waits for.
//!
//! Only the drawing thread draws: mpv compiles the shaders it draws a video with on its first
//! frames, a tenth of a second or more each, and the window waits for a frame at a new size at
//! most [`FRAME_WAIT`], so a slow frame holds up the picture but not the window. The shaders
//! are kept on disk ([`shader_cache`]) and compiled once.

mod shape;

use std::{
    path::PathBuf,
    sync::{Arc, Condvar, Mutex, MutexGuard},
    thread::JoinHandle,
    time::{Duration, Instant},
};

use nsh_platform_windows::{
    ComponentContext, NativeComponent, Placement,
    windows::{
        Win32::{
            Foundation::HMODULE,
            Graphics::{
                Direct3D::D3D_DRIVER_TYPE_HARDWARE,
                Direct3D11::{
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_SDK_VERSION,
                    D3D11CreateDevice, ID3D11Device, ID3D11Multithread, ID3D11Texture2D,
                },
                DirectComposition::{
                    IDCompositionDesktopDevice, IDCompositionRectangleClip, IDCompositionVisual2, IDCompositionVisual3,
                },
                Dxgi::{
                    Common::{
                        DXGI_ALPHA_MODE_PREMULTIPLIED, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_UNKNOWN,
                        DXGI_SAMPLE_DESC,
                    },
                    DXGI_PRESENT, DXGI_SCALING_STRETCH, DXGI_SWAP_CHAIN_DESC1, DXGI_SWAP_CHAIN_FLAG,
                    DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, DXGI_USAGE_RENDER_TARGET_OUTPUT, IDXGIDevice, IDXGIFactory2,
                    IDXGISwapChain1,
                },
            },
        },
        core::Interface,
    },
};
use serde_json::Value as JsonValue;

use self::shape::WindowShape;
use crate::{
    player::{Emit, Player, Screen},
    render::{Api, Render},
};

/// What the drawing thread draws with, and into.
struct Target {
    render: Option<Render>,
    swap_chain: Option<IDXGISwapChain1>,
}

// SAFETY: the render context and the swap chain are used by one thread at a time (the mutex);
// the device was made with Direct3D's multithread protection, which mpv turns on.
unsafe impl Send for Target {}

/// Between the window and the drawing thread: something to draw, a size to take, time to
/// stop, and which sizes are drawn.
#[derive(Default)]
struct Wake {
    state: Mutex<Waking>,
    /// Wakes the drawing thread.
    signal: Condvar,
    /// Tells the window a size is drawn.
    drawn: Condvar,
}

#[derive(Default)]
struct Waking {
    draw: bool,
    stop: bool,
    /// The size the swap chain is to take, not taken yet.
    size: Option<(u32, u32)>,
    /// How many sizes were asked for, and how many of those are drawn (or given up).
    asked: u64,
    done: u64,
}

impl Wake {
    fn state(&self) -> MutexGuard<'_, Waking> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn draw(&self) {
        self.state().draw = true;
        self.signal.notify_one();
    }

    /// The swap chain is to take `size` and the frame be drawn at it: the number of this size,
    /// to wait for with [`Self::wait_drawn`].
    fn resize(&self, size: (u32, u32)) -> u64 {
        let mut state = self.state();
        state.size = Some(size);
        state.asked += 1;
        state.draw = true;
        self.signal.notify_one();
        state.asked
    }

    /// The size asked for last, if not taken yet, and its number, for [`Self::drawn`].
    fn take_size(&self) -> Option<((u32, u32), u64)> {
        let mut state = self.state();
        let asked = state.asked;
        state.size.take().map(|size| (size, asked))
    }

    /// The sizes up to number `asked` are drawn, or given up.
    fn drawn(&self, asked: u64) {
        let mut state = self.state();
        state.done = state.done.max(asked);
        self.drawn.notify_all();
    }

    /// Waits at most `wait` for size number `asked` to be drawn: whether it was.
    fn wait_drawn(&self, asked: u64, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        let mut state = self.state();
        while state.done < asked && !state.stop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            state = self.drawn.wait_timeout(state, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        state.done >= asked
    }

    fn stop(&self) {
        self.state().stop = true;
        self.signal.notify_one();
        self.drawn.notify_all();
    }

    /// Waits for something to draw: false once it is time to stop.
    fn wait(&self) -> bool {
        let mut state = self.state();
        while !state.draw && !state.stop {
            state = self.signal.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        state.draw = false;
        !state.stop
    }
}

/// How long the window waits for the frame at a new size of the view before it shows the
/// window anyway: long enough for a frame of a playing video, and for one being drawn before
/// it, not for the first frames of one, whose shaders mpv compiles.
const FRAME_WAIT: Duration = Duration::from_millis(30);

/// Where mpv keeps the shaders it compiles, so that a video's first frames are not slowed by
/// compiling them again: the app's local (not roaming) data, as they belong to this GPU.
/// `None` when the app keeps nothing (`LISTENOOK_EPHEMERAL`).
fn shader_cache() -> Option<String> {
    if std::env::var_os("LISTENOOK_EPHEMERAL").is_some() {
        return None;
    }
    let dir = PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join("Capyvibe").join("Listenook").join("mpv-shaders");
    std::fs::create_dir_all(&dir).inspect_err(|why| log::warn!("no folder for mpv's shaders: {why}")).ok()?;
    dir.into_os_string().into_string().ok()
}

pub(crate) struct Video {
    player: Player,
    gpu: Option<Gpu>,
    target: Arc<Mutex<Target>>,
    wake: Arc<Wake>,
    drawing: Option<JoinHandle<()>>,
    composition: Option<Visuals>,
    size: (i32, i32),
    /// The swap chain was made and shown.
    made: bool,
    shape: WindowShape,
}

/// The picture's visuals, as nsh stacks a web view's: an outer one with what its ancestors
/// leave visible (window pixels) and its opacity, holding an inner one with its transform and
/// rounded corners, whose content is the swap chain.
struct Visuals {
    outer: IDCompositionVisual2,
    inner: IDCompositionVisual2,
    corners: IDCompositionRectangleClip,
}

impl Visuals {
    fn new(device: &IDCompositionDesktopDevice) -> nsh_platform_windows::windows::core::Result<Visuals> {
        // SAFETY: DirectComposition's documented API, on the window's thread.
        unsafe {
            let outer = device.CreateVisual()?;
            let inner = device.CreateVisual()?;
            let corners = device.CreateRectangleClip()?;
            inner.SetClip(&corners)?;
            outer.AddVisual(&inner, true, None)?;
            Ok(Visuals { outer, inner, corners })
        }
    }

    /// Puts the picture at `at` (the window commits after `placed`).
    fn place(&self, at: &Placement) {
        let (width, height) = (at.size.0 as f32, at.size.1 as f32);
        let corners = &self.corners;
        let [top_left, top_right, bottom_right, bottom_left] = at.radii;
        // SAFETY: DirectComposition's documented API, on the window's thread.
        unsafe {
            let _ = self.inner.SetTransform2(&at.matrix);
            let _ = corners.SetLeft2(0.0);
            let _ = corners.SetTop2(0.0);
            let _ = corners.SetRight2(width);
            let _ = corners.SetBottom2(height);
            let _ = corners.SetTopLeftRadiusX2(top_left);
            let _ = corners.SetTopLeftRadiusY2(top_left);
            let _ = corners.SetTopRightRadiusX2(top_right);
            let _ = corners.SetTopRightRadiusY2(top_right);
            let _ = corners.SetBottomRightRadiusX2(bottom_right);
            let _ = corners.SetBottomRightRadiusY2(bottom_right);
            let _ = corners.SetBottomLeftRadiusX2(bottom_left);
            let _ = corners.SetBottomLeftRadiusY2(bottom_left);
            let _ = self.outer.SetClip2(&at.clip);
            if let Ok(outer) = self.outer.cast::<IDCompositionVisual3>() {
                let _ = outer.SetOpacity2(at.alpha.clamp(0.0, 1.0));
            }
        }
    }
}

/// The Direct3D device mpv draws with, and the factory of its swap chains.
struct Gpu {
    device: ID3D11Device,
    factory: IDXGIFactory2,
}

impl Gpu {
    fn new() -> nsh_platform_windows::windows::core::Result<Gpu> {
        let mut device = None;
        // SAFETY: Direct3D's documented API; `device` is written.
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                None,
            )?;
        }
        let device = device.expect("D3D11CreateDevice made a device");
        // mpv draws on its own threads and the drawing thread presents: the device is shared.
        if let Ok(multithread) = device.cast::<ID3D11Multithread>() {
            // SAFETY: Direct3D's documented API on a live device.
            unsafe {
                let _ = multithread.SetMultithreadProtected(true);
            }
        }
        // SAFETY: DXGI's documented API on a live device.
        let factory = unsafe { device.cast::<IDXGIDevice>()?.GetAdapter()?.GetParent::<IDXGIFactory2>()? };
        Ok(Gpu { device, factory })
    }

    fn swap_chain(&self, (width, height): (i32, i32)) -> nsh_platform_windows::windows::core::Result<IDXGISwapChain1> {
        let desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: width.max(1) as u32,
            Height: height.max(1) as u32,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: 2,
            Scaling: DXGI_SCALING_STRETCH,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            AlphaMode: DXGI_ALPHA_MODE_PREMULTIPLIED,
            ..Default::default()
        };
        // SAFETY: DXGI's documented API, with a device of this factory's adapter.
        unsafe { self.factory.CreateSwapChainForComposition(&self.device, &desc, None) }
    }
}

/// Draws mpv's current frame into `swap_chain` and shows it, after `vsyncs` vertical blanks
/// (0: at once).
fn present(render: &Render, swap_chain: &IDXGISwapChain1, vsyncs: u32) {
    // SAFETY: the swap chain's first buffer is a texture mpv may render to; it is shown after.
    unsafe {
        let Ok(texture) = swap_chain.GetBuffer::<ID3D11Texture2D>(0) else { return };
        render.draw_texture(texture.as_raw());
        drop(texture);
        let _ = swap_chain.Present(vsyncs, DXGI_PRESENT(0));
    }
    render.shown();
}

/// Gives `swap_chain` buffers of `size`: whether it has them.
fn resize_buffers(swap_chain: &IDXGISwapChain1, (width, height): (u32, u32)) -> bool {
    // SAFETY: nothing holds the swap chain's buffers: frames take and let go of them on this
    // thread, and mpv keeps none.
    unsafe { swap_chain.ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG(0)) }
        .inspect_err(|why| log::warn!("mpv's picture cannot take its new size: {why}"))
        .is_ok()
}

/// Draws whenever woken, until told to stop: at a size asked for first, at once, then telling
/// the window it is drawn.
fn draw(target: &Mutex<Target>, wake: &Wake) {
    while wake.wait() {
        let asked = wake.take_size();
        {
            let target = target.lock().unwrap_or_else(|e| e.into_inner());
            if let (Some(render), Some(swap_chain)) = (&target.render, &target.swap_chain) {
                let resized = asked.is_some_and(|(size, _)| resize_buffers(swap_chain, size));
                let new = render.has_frame();
                if resized || new {
                    present(render, swap_chain, if resized { 0 } else { 1 });
                }
            }
        }
        if let Some((_, number)) = asked {
            wake.drawn(number);
        }
    }
}

impl Video {
    pub(crate) fn make(cx: ComponentContext) -> Box<dyn NativeComponent> {
        let emit: Emit = Arc::new(move |name, data| cx.emit(name, data));
        let mut options = vec![("vo", "libmpv".into())];
        options.extend(shader_cache().map(|dir| ("gpu-shader-cache-dir", dir)));
        let screen = Screen { options, wid: None, keep: Box::new(()), before_playing: None };
        let player = Player::new(screen, emit);
        let target = Arc::new(Mutex::new(Target { render: None, swap_chain: None }));
        let wake = Arc::new(Wake::default());
        let gpu = match Gpu::new() {
            Ok(gpu) => Some(gpu),
            Err(why) => {
                log::error!("no Direct3D 11 device for mpv: videos play without their picture ({why})");
                None
            }
        };
        if let Some(gpu) = &gpu {
            let woken = wake.clone();
            match player.output().render(Api::Direct3D11(gpu.device.as_raw()), Box::new(move || woken.draw())) {
                Ok(render) => target.lock().unwrap_or_else(|e| e.into_inner()).render = Some(render),
                Err(why) => log::error!("mpv cannot draw with Direct3D 11: {why}"),
            }
        }
        let (drawn, woken) = (target.clone(), wake.clone());
        let drawing = std::thread::Builder::new()
            .name("mpv-draw".into())
            .spawn(move || draw(&drawn, &woken))
            .inspect_err(|why| log::error!("mpv's drawing thread could not start: {why}"))
            .ok();
        Box::new(Video {
            player,
            gpu,
            target,
            wake,
            drawing,
            composition: None,
            size: (0, 0),
            made: false,
            shape: WindowShape::default(),
        })
    }

    /// The swap chain takes `size`: made the first time and shown in the visual, its buffers
    /// resized after, by the drawing thread, which draws the current frame at the new size at
    /// once; the window waits for it at most [`FRAME_WAIT`], so the picture keeps up with the
    /// window, and until it is shown the compositor keeps showing the frame before. (A new swap
    /// chain at each size showed nothing until it was drawn into, which flashed, and was slow
    /// to make; a frame drawn by the window held it up while mpv compiled shaders.)
    fn resize(&mut self, size: (i32, i32)) {
        self.size = size;
        let size = (size.0.max(1) as u32, size.1.max(1) as u32);
        if !self.made {
            self.made = self.make_swap_chain(size);
            return;
        }
        let asked = self.wake.resize(size);
        self.wake.wait_drawn(asked, FRAME_WAIT);
    }

    /// Makes the swap chain, of `size`, has the current frame drawn into it and shows it in the
    /// visual: whether it did.
    fn make_swap_chain(&self, (width, height): (u32, u32)) -> bool {
        let (Some(gpu), Some(visuals)) = (&self.gpu, &self.composition) else { return false };
        let swap_chain = match gpu.swap_chain((width as i32, height as i32)) {
            Ok(swap_chain) => swap_chain,
            Err(why) => {
                log::warn!("no swap chain for mpv's picture: {why}");
                return false;
            }
        };
        // The drawing thread has had nothing to draw into, so it does not hold this for long.
        self.target.lock().unwrap_or_else(|e| e.into_inner()).swap_chain = Some(swap_chain.clone());
        let asked = self.wake.resize((width, height));
        self.wake.wait_drawn(asked, FRAME_WAIT);
        // SAFETY: DirectComposition's documented API; the window commits after `placed`.
        if let Err(why) = unsafe { visuals.inner.SetContent(&swap_chain) } {
            log::warn!("mpv's picture cannot be shown: {why}");
        }
        true
    }
}

impl NativeComponent for Video {
    fn composed(&self) -> bool {
        true
    }

    fn visual(&mut self, device: &IDCompositionDesktopDevice) -> Option<IDCompositionVisual2> {
        let visuals = Visuals::new(device).inspect_err(|why| log::warn!("no visual for mpv's picture: {why}")).ok()?;
        let outer = visuals.outer.clone();
        self.composition = Some(visuals);
        Some(outer)
    }

    fn placed(&mut self, at: Option<Placement>) {
        let Some(at) = at else { return };
        if at.size != self.size && at.size.0 > 0 && at.size.1 > 0 {
            self.resize(at.size);
        }
        if let Some(visuals) = &self.composition {
            visuals.place(&at);
        }
        self.shape.placed(&at);
    }

    fn set_prop(&mut self, name: &str, value: Option<&JsonValue>) {
        if name == "windowShape" {
            let size = value
                .and_then(JsonValue::as_array)
                .and_then(|pair| Some((pair.first()?.as_f64()?, pair.get(1)?.as_f64()?)));
            self.shape.set(size);
            return;
        }
        self.player.set_prop(name, value);
    }

    fn command(&mut self, name: &str, args: &JsonValue) {
        self.player.command(name, args);
    }
}

impl Drop for Video {
    /// The drawing thread stops and the render context goes before the player stops mpv.
    fn drop(&mut self) {
        self.wake.stop();
        if let Some(drawing) = self.drawing.take() {
            let _ = drawing.join();
        }
        self.target.lock().unwrap_or_else(|e| e.into_inner()).render.take();
    }
}
