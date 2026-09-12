//! The tray icon: Open and Quit, and nothing else.
//!
//! It owns the main thread. On macOS a status item only works on the thread
//! running the NSApplication loop, which must be the main one; on Windows
//! the icon's hidden window gets its messages only from a loop on the thread
//! that created it. The server runs on a tokio runtime on another thread and
//! tells this loop when it has finished stopping.

use std::time::{Duration, Instant};

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoop, EventLoopBuilder, EventLoopProxy};
use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

enum UserEvent {
    Menu(MenuEvent),
    Icon(TrayIconEvent),
    ServerStopped,
}

/// How long Quit waits for the server thread before exiting regardless.
/// The server caps its own shutdown well below this; this is for the case
/// where that thread is wedged, and an icon that stays after Quit reads as
/// a Quit that did nothing.
const QUIT_DEADLINE: Duration = Duration::from_secs(10);

/// A click within this long of the last open is ignored. A Win32 double-click
/// arrives as button-up, double-click, button-up, and tray-icon passes each
/// on; opening on every one would put up to three identical tabs in the
/// browser.
const OPEN_DEBOUNCE: Duration = Duration::from_millis(1500);

/// Whether a tray can be shown at all. An SSH session or a launchd daemon on
/// macOS has no window server to put a status item in; NSApplication still
/// starts there and the icon silently never appears, so the process would
/// look hung with no Quit.
pub fn available() -> bool {
    #[cfg(target_os = "macos")]
    {
        macos_gui_session()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

#[cfg(target_os = "macos")]
fn macos_gui_session() -> bool {
    use std::ffi::c_void;
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGSessionCopyCurrentDictionary() -> *const c_void;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFRelease(cf: *const c_void);
    }
    // SAFETY: both are plain C calls with no preconditions; the dictionary
    // is released only when one was returned.
    unsafe {
        let dict = CGSessionCopyCurrentDictionary();
        if dict.is_null() {
            return false;
        }
        CFRelease(dict);
        true
    }
}

pub struct Tray {
    event_loop: EventLoop<UserEvent>,
}

/// Handed to the server thread so the tray loop learns when shutdown is done.
pub struct StoppedNotifier(EventLoopProxy<UserEvent>);

impl StoppedNotifier {
    pub fn notify(&self) {
        let _ = self.0.send_event(UserEvent::ServerStopped);
    }
}

impl Tray {
    /// Must be called on the main thread.
    pub fn new() -> Self {
        #[allow(unused_mut)]
        let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
        #[cfg(target_os = "macos")]
        {
            use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
            // Regular, tao's default, puts a Dock icon and an app menu on a
            // process whose only UI is the status item.
            event_loop.set_activation_policy(ActivationPolicy::Accessory);
        }
        // Forwarded into the loop rather than polled: a receiver read on each
        // turn is never woken on macOS, where the loop sleeps until an event
        // of its own arrives, so a click would sit unread.
        let proxy = event_loop.create_proxy();
        TrayIconEvent::set_event_handler(Some(move |e| {
            let _ = proxy.send_event(UserEvent::Icon(e));
        }));
        let proxy = event_loop.create_proxy();
        MenuEvent::set_event_handler(Some(move |e| {
            let _ = proxy.send_event(UserEvent::Menu(e));
        }));
        Self { event_loop }
    }

    pub fn stopped_notifier(&self) -> StoppedNotifier {
        StoppedNotifier(self.event_loop.create_proxy())
    }

    /// Runs until the server has stopped after Quit. `on_quit` asks the
    /// server to stop; it is called once.
    pub fn run(self, port: u16, on_quit: impl FnOnce() + 'static) -> ! {
        let open_item = MenuItem::new("Open Anicat", true, None);
        let quit_item = MenuItem::new("Quit", true, None);
        let menu = Menu::new();
        let _ = menu.append(&open_item);
        let _ = menu.append(&quit_item);
        let open_id = open_item.id().clone();
        let quit_id = quit_item.id().clone();

        let mut menu = Some(menu);
        // Held, never read: dropping the TrayIcon is what removes it.
        let mut _icon: Option<TrayIcon> = None;
        let mut on_quit = Some(on_quit);
        let mut last_open: Option<Instant> = None;

        let mut open_page = move || {
            if last_open.is_some_and(|t| t.elapsed() < OPEN_DEBOUNCE) {
                return;
            }
            last_open = Some(Instant::now());
            crate::open_browser(port);
        };

        self.event_loop.run(move |event, _, control_flow| {
            if *control_flow != ControlFlow::Exit && on_quit.is_some() {
                *control_flow = ControlFlow::Wait;
            }
            match event {
                // Not before: on macOS a status item built before the loop is
                // running can fail to show over a full-screen app, per
                // tray-icon's own platform notes.
                Event::NewEvents(StartCause::Init) => {
                    if let Some(menu) = menu.take() {
                        match build_icon(menu) {
                            Ok(t) => _icon = Some(t),
                            // The server keeps running; Ctrl-C or the page's
                            // own controls still work. Exiting here would take
                            // down a working engine over a cosmetic failure.
                            Err(e) => log::error!("tray icon failed: {e}"),
                        }
                    }
                }
                Event::UserEvent(UserEvent::Menu(e)) => {
                    if e.id == open_id {
                        open_page();
                    } else if e.id == quit_id {
                        if let Some(quit) = on_quit.take() {
                            log::info!("quit from the tray");
                            // Gone at once: shutdown can take seconds while mpv
                            // closes, and an icon still sitting there reads as
                            // a Quit that did nothing.
                            _icon = None;
                            quit();
                            *control_flow = ControlFlow::WaitUntil(Instant::now() + QUIT_DEADLINE);
                        }
                    }
                }
                Event::UserEvent(UserEvent::Icon(TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                })) => {
                    // macOS shows the menu on a left click, as every status
                    // item does; opening the page as well would steal focus
                    // from the menu that just appeared.
                    if cfg!(windows) {
                        open_page();
                    }
                }
                Event::UserEvent(UserEvent::Icon(TrayIconEvent::DoubleClick {
                    button: MouseButton::Left,
                    ..
                })) => {
                    if cfg!(windows) {
                        open_page();
                    }
                }
                Event::UserEvent(UserEvent::ServerStopped) => {
                    _icon = None;
                    *control_flow = ControlFlow::Exit;
                }
                Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                    log::warn!("server did not stop within {QUIT_DEADLINE:?} of Quit; exiting anyway");
                    *control_flow = ControlFlow::Exit;
                }
                _ => {}
            }
        })
    }
}

fn build_icon(menu: Menu) -> Result<TrayIcon, String> {
    let builder = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("Anicat")
        .with_icon(icon()?);
    // A template image is drawn by macOS in the menu bar's own colour, so the
    // black paw stays visible on a dark menu bar and a tinted wallpaper.
    #[cfg(target_os = "macos")]
    let builder = builder.with_icon_as_template(true);
    // Windows: left click opens the page, right click is the menu. With the
    // menu on both, the page could only be reached through a second click.
    #[cfg(windows)]
    let builder = builder.with_menu_on_left_click(false);
    builder.build().map_err(|e| e.to_string())
}

/// The black paw on macOS, used as a template. Windows draws a tray icon as
/// given, and black disappears on the default dark taskbar, so it gets the
/// app icon's blue paw, which reads on both the dark and the light one.
fn icon() -> Result<Icon, String> {
    #[cfg(target_os = "macos")]
    const PNG: &[u8] = include_bytes!("../assets/tray-template.png");
    #[cfg(not(target_os = "macos"))]
    const PNG: &[u8] = include_bytes!("../assets/tray-color.png");

    let mut decoder = png::Decoder::new(std::io::Cursor::new(PNG));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().map_err(|e| e.to_string())?;
    let mut buf = vec![0; reader.output_buffer_size().ok_or("icon too large")?];
    let info = reader.next_frame(&mut buf).map_err(|e| e.to_string())?;
    if info.color_type != png::ColorType::Rgba {
        return Err(format!("tray icon is {:?}, expected RGBA", info.color_type));
    }
    buf.truncate(info.buffer_size());
    Icon::from_rgba(buf, info.width, info.height).map_err(|e| e.to_string())
}
