//! On Windows, mpv draws with Direct3D 11 into a composition swap chain, the content of a
//! DirectComposition visual that nsh stacks with what it draws: the picture is placed, clipped,
//! rounded and covered like the rest of the window. Frames are drawn on a thread of their own
//! as mpv has them; the swap chain is made again at each new size.

use std::{
    sync::{Arc, Condvar, Mutex},
    thread::JoinHandle,
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
                    Common::{DXGI_ALPHA_MODE_PREMULTIPLIED, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC},
                    DXGI_PRESENT, DXGI_SCALING_STRETCH, DXGI_SWAP_CHAIN_DESC1, DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
                    DXGI_USAGE_RENDER_TARGET_OUTPUT, IDXGIDevice, IDXGIFactory2, IDXGISwapChain1,
                },
            },
        },
        core::Interface,
    },
};
use serde_json::Value as JsonValue;

use crate::{
    player::{Emit, Player, Screen},
    render::{Api, Render},
};

/// What the drawing thread draws with, and into.
struct Target {
    render: Option<Render>,
    swap_chain: Option<IDXGISwapChain1>,
    /// The swap chain is new: the frame is drawn again even when mpv has none.
    fresh: bool,
}

// SAFETY: the render context and the swap chain are used by one thread at a time (the mutex);
// the device was made with Direct3D's multithread protection, which mpv turns on.
unsafe impl Send for Target {}

/// Wakes the drawing thread: something to draw, or time to stop.
#[derive(Default)]
struct Wake {
    state: Mutex<(bool, bool)>,
    signal: Condvar,
}

impl Wake {
    fn draw(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).0 = true;
        self.signal.notify_one();
    }

    fn stop(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).1 = true;
        self.signal.notify_one();
    }

    /// Waits for something to draw: false once it is time to stop.
    fn wait(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        while !state.0 && !state.1 {
            state = self.signal.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        state.0 = false;
        !state.1
    }
}

pub(crate) struct Video {
    player: Player,
    gpu: Option<Gpu>,
    target: Arc<Mutex<Target>>,
    wake: Arc<Wake>,
    drawing: Option<JoinHandle<()>>,
    composition: Option<Visuals>,
    size: (i32, i32),
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

/// Draws whenever woken, until told to stop.
fn draw(target: &Mutex<Target>, wake: &Wake) {
    while wake.wait() {
        let mut target = target.lock().unwrap_or_else(|e| e.into_inner());
        let fresh = std::mem::take(&mut target.fresh);
        let (Some(render), Some(swap_chain)) = (&target.render, &target.swap_chain) else { continue };
        if !(render.has_frame() || fresh) {
            continue;
        }
        // SAFETY: the swap chain's first buffer is a texture mpv may render to; it is shown after.
        unsafe {
            let Ok(texture) = swap_chain.GetBuffer::<ID3D11Texture2D>(0) else { continue };
            render.draw_texture(texture.as_raw());
            drop(texture);
            let _ = swap_chain.Present(1, DXGI_PRESENT(0));
        }
        render.shown();
    }
}

impl Video {
    pub(crate) fn make(cx: ComponentContext) -> Box<dyn NativeComponent> {
        let emit: Emit = Arc::new(move |name, data| cx.emit(name, data));
        let screen =
            Screen { options: vec![("vo", "libmpv".into())], wid: None, keep: Box::new(()), before_playing: None };
        let player = Player::new(screen, emit);
        let target = Arc::new(Mutex::new(Target { render: None, swap_chain: None, fresh: false }));
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
        Box::new(Video { player, gpu, target, wake, drawing, composition: None, size: (0, 0) })
    }

    /// A new swap chain of `size`, shown in the visual from now on.
    fn resize(&mut self, size: (i32, i32)) {
        let (Some(gpu), Some(visuals)) = (&self.gpu, &self.composition) else { return };
        match gpu.swap_chain(size) {
            Ok(swap_chain) => {
                // SAFETY: DirectComposition's documented API; the window commits after `placed`.
                if let Err(why) = unsafe { visuals.inner.SetContent(&swap_chain) } {
                    log::warn!("mpv's picture cannot be shown: {why}");
                }
                let mut target = self.target.lock().unwrap_or_else(|e| e.into_inner());
                target.swap_chain = Some(swap_chain);
                target.fresh = true;
                self.size = size;
            }
            Err(why) => log::warn!("no swap chain for mpv's picture: {why}"),
        }
        self.wake.draw();
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
    }

    fn set_prop(&mut self, name: &str, value: Option<&JsonValue>) {
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
