//! On iOS, mpv draws through MoltenVK (Metal) into a `CAMetalLayer` inside a view (a sublayer:
//! MoltenVK changes it from its own threads, which UIKit refuses for a view's own layer). mpv
//! learns the size it draws at only as a video starts, so the layer takes the video's own size
//! then, before anything is decoded, and keeps it: a scale fits it into the view however the
//! view changes size later. In the background the picture is turned off and the sound plays on:
//! iOS refuses GPU work from apps there.

use std::{cell::RefCell, sync::Arc};

use dispatch2::DispatchQueue;
use nsh_platform_ios::{ComponentContext, NativeComponent};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, class, define_class, msg_send,
    rc::Retained,
    runtime::{AnyObject, Bool, NSObject},
    sel,
};
use objc2_core_foundation::{CGAffineTransform, CGPoint, CGRect, CGSize};
use objc2_foundation::{NSNotification, NSNotificationCenter, NSString};
use objc2_quartz_core::{CAMetalLayer, CATransaction};
use objc2_ui_kit::{UIResponder, UIView};
use serde_json::Value as JsonValue;

use crate::player::{Emit, Output, Player, Screen};

/// The longest side mpv draws a picture at; the layer scales it to the view.
const LONGEST: f64 = 2560.0;

define_class!(
    /// The view mpv draws in. Touches go through it to what the app put under or around it.
    #[unsafe(super(UIView, UIResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "ListenookMpvView"]
    #[ivars = ViewState]
    struct MpvView;

    impl MpvView {
        #[unsafe(method(layoutSubviews))]
        fn layout_subviews(&self) {
            // SAFETY: UIView's own implementation.
            let _: () = unsafe { msg_send![super(self), layoutSubviews] };
            fit(&self.ivars().layer, self.bounds());
        }

        #[unsafe(method(enteredBackground:))]
        fn entered_background(&self, _note: &NSNotification) {
            self.show_picture(false);
        }

        #[unsafe(method(enteringForeground:))]
        fn entering_foreground(&self, _note: &NSNotification) {
            self.show_picture(true);
        }
    }
);

struct ViewState {
    layer: Retained<CAMetalLayer>,
    output: RefCell<Option<Output>>,
}

impl MpvView {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let layer = CAMetalLayer::new();
        layer.setOpaque(false);
        let this = Self::alloc(mtm).set_ivars(ViewState { layer, output: RefCell::new(None) });
        // SAFETY: UIView's designated initializer for a view laid out by its parent.
        let this: Retained<Self> = unsafe { msg_send![super(this), init] };
        this.setUserInteractionEnabled(false);
        this.layer().addSublayer(&this.ivars().layer);
        this
    }

    /// Turns the picture off in the background, and on again in the foreground.
    fn follow_app(&self, output: Output) {
        self.ivars().output.replace(Some(output));
        let center = NSNotificationCenter::defaultCenter();
        for (selector, name) in [
            (sel!(enteredBackground:), "UIApplicationDidEnterBackgroundNotification"),
            (sel!(enteringForeground:), "UIApplicationWillEnterForegroundNotification"),
        ] {
            // SAFETY: the view answers the selector; it stops observing in `stop_following`.
            unsafe { center.addObserver_selector_name_object(self, selector, Some(&NSString::from_str(name)), None) };
        }
    }

    fn stop_following(&self) {
        // SAFETY: removes this view's observations, added in `follow_app`.
        unsafe { NSNotificationCenter::defaultCenter().removeObserver(self) };
    }

    fn show_picture(&self, on: bool) {
        if let Some(output) = self.ivars().output.borrow().as_ref() {
            output.show_picture(on);
        }
    }
}

/// The layer, as mpv's threads hold it: they draw into it and size it (a CAMetalLayer's
/// drawable size may be set from any thread). Its last reference goes on the main thread.
struct Layer(Option<Retained<CAMetalLayer>>);

/// The layer on its way to the main thread, only to be released there.
struct Releasing(#[allow(dead_code, reason = "held only to be released")] Retained<CAMetalLayer>);

// SAFETY: off the main thread the layer is only sized, retained and released.
unsafe impl Send for Layer {}
// SAFETY: as above.
unsafe impl Sync for Layer {}
// SAFETY: it is only released, on the main thread.
unsafe impl Send for Releasing {}

impl Drop for Layer {
    fn drop(&mut self) {
        if let Some(layer) = self.0.take() {
            let releasing = Releasing(layer);
            DispatchQueue::main().exec_async(move || drop(releasing));
        }
    }
}

impl Layer {
    /// Gives the layer the size (width, height) of the video mpv is about to play.
    fn fit_video(&self, (width, height): (f64, f64)) {
        let Some(layer) = &self.0 else { return };
        let scale = (LONGEST / width.max(height)).min(1.0);
        let size = CGSize::new((width * scale).round(), (height * scale).round());
        // An explicit transaction: this thread has no run loop to commit an implicit one.
        CATransaction::begin();
        CATransaction::setDisableActions(true);
        layer.setBounds(CGRect::new(CGPoint::ZERO, size));
        layer.setDrawableSize(size);
        CATransaction::commit();
        let fitting = Layer(Some(layer.clone()));
        DispatchQueue::main().exec_async(move || {
            if let Some(layer) = &fitting.0
                && let Some(view) = layer.superlayer()
            {
                fit(layer, view.bounds());
            }
        });
    }
}

/// Scales `layer` (at the size of the picture mpv draws) to fit `bounds` whole, centered.
fn fit(layer: &CAMetalLayer, bounds: CGRect) {
    let size = layer.bounds().size;
    let scale = if size.width > 0.0 && size.height > 0.0 {
        (bounds.size.width / size.width).min(bounds.size.height / size.height)
    } else {
        1.0
    };
    CATransaction::begin();
    CATransaction::setDisableActions(true);
    layer.setPosition(CGPoint::new(
        bounds.origin.x + bounds.size.width / 2.0,
        bounds.origin.y + bounds.size.height / 2.0,
    ));
    layer.setAffineTransform(CGAffineTransform { a: scale, b: 0.0, c: 0.0, d: scale, tx: 0.0, ty: 0.0 });
    CATransaction::commit();
}

/// Puts the app's sound in the playback category (spoken audio), active, so it plays on in the
/// background and with the ringer off.
fn play_in_background() {
    // SAFETY: AVAudioSession's documented API; the category and mode strings are its constants.
    unsafe {
        let session: Retained<AnyObject> = msg_send![class!(AVAudioSession), sharedInstance];
        let category = NSString::from_str("AVAudioSessionCategoryPlayback");
        let mode = NSString::from_str("AVAudioSessionModeSpokenAudio");
        let error: *mut *mut AnyObject = std::ptr::null_mut();
        let _: Bool = msg_send![&*session, setCategory: &*category, mode: &*mode, options: 0_usize, error: error];
        let _: Bool = msg_send![&*session, setActive: true, error: error];
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
        let view = MpvView::new(mtm);
        let layer = view.ivars().layer.clone();
        let wid = Retained::as_ptr(&layer) as i64;
        let layer = Arc::new(Layer(Some(layer)));
        let sizes = layer.clone();
        let screen = Screen {
            options: vec![("vo", "gpu-next".into()), ("gpu-api", "vulkan".into()), ("gpu-context", "moltenvk".into())],
            wid: Some(wid),
            keep: Box::new(layer),
            before_playing: Some(Box::new(move |size| sizes.fit_video(size))),
        };
        let player = Player::new(screen, emit);
        view.follow_app(player.output());
        Box::new(Video { view, player })
    }
}

impl NativeComponent for Video {
    fn view(&self) -> &UIView {
        &self.view
    }

    fn set_prop(&mut self, name: &str, value: Option<&JsonValue>) {
        let playing = value.and_then(|playback| playback.get("paused")).and_then(JsonValue::as_bool) == Some(false);
        if name == "playback" && playing {
            play_in_background();
        }
        self.player.set_prop(name, value);
    }

    fn command(&mut self, name: &str, args: &JsonValue) {
        self.player.command(name, args);
    }
}

impl Drop for Video {
    fn drop(&mut self) {
        self.view.stop_following();
    }
}
