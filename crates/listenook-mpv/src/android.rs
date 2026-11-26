//! On Android, mpv draws with OpenGL ES into the `Surface` of a `TextureView`, as mpv-android
//! does: a texture view is placed, clipped and moved like any view. Its listener is a Java proxy
//! (nsh's `proxy`), which hands each new surface to mpv (`wid`), tells it the surface's size,
//! and takes the surface back before Android destroys it; the sound plays on meanwhile.

use std::sync::{Arc, Mutex, Once};

use nsh::{
    ComponentContext, NativeComponent,
    jni::{
        JNIEnv,
        objects::{GlobalRef, JObject, JObjectArray, JValue},
    },
    proxy::{self, Proxy},
};
use serde_json::Value as JsonValue;

use crate::player::{Emit, Output, Player, Screen};

unsafe extern "C" {
    /// FFmpeg's hold of the Java VM, which its MediaCodec decoders need.
    fn av_jni_set_java_vm(vm: *mut std::ffi::c_void, log_ctx: *mut std::ffi::c_void) -> std::ffi::c_int;
}

/// The surface mpv draws into, while there is one.
type Surface = Arc<Mutex<Option<GlobalRef>>>;

pub(crate) struct Video {
    view: GlobalRef,
    player: Player,
    _listener: Option<Proxy>,
    surface: Surface,
}

/// Hands FFmpeg the Java VM, once.
fn share_vm(env: &JNIEnv<'_>) {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        if let Ok(vm) = env.get_java_vm() {
            // SAFETY: the process's Java VM, which lives as long as the process.
            unsafe { av_jni_set_java_vm(vm.get_java_vm_pointer().cast(), std::ptr::null_mut()) };
        }
    });
}

/// `(width, height)` of a `SurfaceTextureListener` call's last two arguments.
fn size_of(env: &mut JNIEnv<'_>, args: &JObjectArray<'_>) -> Option<(i32, i32)> {
    let mut int = |at: i32| -> Option<i32> {
        let boxed = env.get_object_array_element(args, at).ok()?;
        env.call_method(&boxed, "intValue", "()I", &[]).ok()?.i().ok()
    };
    Some((int(1)?, int(2)?))
}

/// Answers the texture view's listener: mpv draws into its surface while it lasts.
fn listen(
    output: &Output,
    surface: &Surface,
    env: &mut JNIEnv<'_>,
    method: &str,
    args: &JObjectArray<'_>,
) -> nsh::jni::errors::Result<Option<GlobalRef>> {
    match method {
        "onSurfaceTextureAvailable" => {
            let texture = env.get_object_array_element(args, 0)?;
            let made = env.new_object(
                "android/view/Surface",
                "(Landroid/graphics/SurfaceTexture;)V",
                &[JValue::Object(&texture)],
            )?;
            let made = env.new_global_ref(made)?;
            output.attach(made.as_obj().as_raw() as i64, size_of(env, args).unwrap_or((1, 1)));
            surface.lock().unwrap_or_else(|e| e.into_inner()).replace(made);
            Ok(None)
        }
        "onSurfaceTextureSizeChanged" => {
            if let Some(size) = size_of(env, args) {
                output.resize(size);
            }
            Ok(None)
        }
        "onSurfaceTextureDestroyed" => {
            output.detach();
            if let Some(gone) = surface.lock().unwrap_or_else(|e| e.into_inner()).take() {
                env.call_method(gone.as_obj(), "release", "()V", &[])?;
            }
            // The texture is the view's to release.
            let done = env.new_object("java/lang/Boolean", "(Z)V", &[JValue::Bool(1)])?;
            Ok(Some(env.new_global_ref(done)?))
        }
        _ => Ok(None),
    }
}

impl Video {
    pub(crate) fn make(cx: ComponentContext) -> Box<dyn NativeComponent> {
        let made = cx.with_env(|env| {
            share_vm(env);
            let view = env.new_object(
                "android/view/TextureView",
                "(Landroid/content/Context;)V",
                &[JValue::Object(cx.android_context().as_obj())],
            )?;
            env.call_method(&view, "setOpaque", "(Z)V", &[JValue::Bool(0)])?;
            env.new_global_ref(view)
        });
        let context = cx.clone();
        let emit: Emit = Arc::new(move |name, data| context.emit(name, data));
        let screen = Screen {
            options: vec![
                ("vo", "null".into()),
                ("gpu-context", "android".into()),
                ("opengl-es", "yes".into()),
                ("force-window", "no".into()),
                ("hwdec", "mediacodec,mediacodec-copy".into()),
                ("ao", "audiotrack,opensles".into()),
            ],
            wid: None,
            keep: Box::new(()),
            before_playing: None,
        };
        let player = Player::new(screen, emit);
        let surface: Surface = Arc::default();
        let view = made.expect("Android makes a TextureView");
        let (output, held) = (player.output(), surface.clone());
        let listener = cx
            .with_env(|env| {
                let listener = proxy::implement(
                    env,
                    &["android.view.TextureView$SurfaceTextureListener"],
                    move |env, method, args| listen(&output, &held, env, method, args),
                )?;
                env.call_method(
                    view.as_obj(),
                    "setSurfaceTextureListener",
                    "(Landroid/view/TextureView$SurfaceTextureListener;)V",
                    &[JValue::Object(listener.as_obj())],
                )?;
                Ok(listener)
            })
            .inspect_err(|why| log::error!("mpv cannot follow its surface: {why}"))
            .ok();
        Box::new(Video { view, player, _listener: listener, surface })
    }
}

impl NativeComponent for Video {
    fn view(&self) -> &GlobalRef {
        &self.view
    }

    fn set_prop(&mut self, _env: &mut JNIEnv<'_>, name: &str, value: Option<&JsonValue>) {
        self.player.set_prop(name, value);
    }

    fn command(&mut self, _env: &mut JNIEnv<'_>, name: &str, args: &JsonValue) {
        self.player.command(name, args);
    }

    /// mpv lets go of the surface before the view goes.
    fn destroy(&mut self, env: &mut JNIEnv<'_>) {
        self.player.output().detach();
        if let Some(gone) = self.surface.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = env.call_method(gone.as_obj(), "release", "()V", &[]);
        }
        let _ = env.call_method(
            self.view.as_obj(),
            "setSurfaceTextureListener",
            "(Landroid/view/TextureView$SurfaceTextureListener;)V",
            &[JValue::Object(&JObject::null())],
        );
    }
}
