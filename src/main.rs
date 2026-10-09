//! Herdr Pixel Dungeon: a native pixel-art guild for your live Herdr agents,
//! for macOS and Linux. Each agent is an animated hero in a dungeon room
//! that changes with its real Herdr status, in a small floating widget with
//! a status item in the menu bar or tray.

mod alerts;
mod assets;
mod events;
mod herdr;
mod l10n;
mod monitor;
mod prefs;
mod scene;
mod selftest;
mod tray;
mod ui;

use alerts::{wants_sound, Notifier, Sounds};
use assets::Assets;
use egui::{vec2, Color32, CornerRadius, Frame, Rect, Vec2, ViewportCommand};
use herdr::{connection_note, StatusFilter};
use l10n::{tr, trf};
use monitor::Monitor;
use prefs::Prefs;
use scene::{Scene, BACKGROUND, GAP, ROW_H};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tray::{MenuState, Tray, TrayAction};
use ui::{ChatState, ComposeState, HudState, HUD_HEIGHT, PANEL_HEIGHT};

/// Room above the first row (drag handle) and below the last one.
const TOP_INSET: f32 = 14.0;
const BOTTOM_INSET: f32 = 6.0;
/// Margin from the screen edges.
const MARGIN: f32 = 12.0;
/// Space the menu bar takes at the top of the screen.
#[cfg(target_os = "macos")]
const SCREEN_TOP: f32 = 25.0;
#[cfg(not(target_os = "macos"))]
const SCREEN_TOP: f32 = 0.0;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--self-test") {
        selftest::run();
        return;
    }
    let prefs = Prefs::load(Prefs::default_path());
    let session = std::env::var("HERDR_SESSION").ok().or_else(|| prefs.session.clone()).unwrap_or_else(|| "default".into());
    if args.iter().any(|a| a == "--diagnose") {
        match herdr::fetch_snapshot(&session) {
            Ok(agents) => {
                println!("OK: {} agentes", agents.len());
                for a in agents { println!("{} | {} | {} | {}", a.id, a.name, a.status, a.project); }
            }
            Err(error) => { eprintln!("{error}"); std::process::exit(1); }
        }
        return;
    }
    let demo = args.iter().any(|a| a == "--demo");
    let on_top = prefs.on_top;
    let mut viewport = egui::ViewportBuilder::default()
        .with_title("Herdr Pixel Dungeon")
        .with_app_id("herdr-pixel-dungeon")
        .with_decorations(false)
        .with_transparent(true)
        .with_resizable(true)
        .with_inner_size([scene::width_for(2), 400.0])
        .with_min_inner_size([scene::width_for(1), 200.0]);
    if on_top { viewport = viewport.with_always_on_top(); }
    let options = eframe::NativeOptions { viewport, centered: false, ..Default::default() };
    let result = eframe::run_native("Herdr Pixel Dungeon", options, Box::new(move |cc| Ok(Box::new(App::new(cc, prefs, session, demo)))));
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

struct App {
    monitor: Monitor,
    prefs: Prefs,
    sounds: Sounds,
    notifier: Notifier,
    scene: Scene,
    assets: Assets,
    tray: Tray,
    chat: Option<ChatState>,
    compose: ComposeState,
    hud: HudState,
    show_log: bool,
    visible: bool,
    first_frame: bool,
    /// The size we asked for; anything else is the user resizing.
    expected: Option<Vec2>,
    commanded_at: Option<Instant>,
    last_size: Option<Vec2>,
    size_changed_at: Option<f64>,
    resize_start: Option<Rect>,
    grip: bool,
    last_outer: Option<Rect>,
    /// The chat (agent id) or "compose" panel that last took the keyboard.
    key_panel: Option<String>,
    login: Option<auto_launch::AutoLaunch>,
    login_enabled: bool,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>, prefs: Prefs, session: String, demo: bool) -> App {
        let ctx = cc.egui_ctx.clone();
        let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(move || ctx.request_repaint());
        let mut monitor = Monitor::new(session, StatusFilter::from_raw(&prefs.filter));
        monitor.set_wake(wake.clone());
        if demo { monitor.demo = true; }
        let mut scene = Scene::new();
        scene.reduced_motion = reduce_motion();
        let login = login_item();
        let login_enabled = login.as_ref().map(|l| l.is_enabled().unwrap_or(false)).unwrap_or(false);
        let mut visuals = egui::Visuals::dark();
        visuals.panel_fill = Color32::TRANSPARENT;
        visuals.window_fill = Color32::TRANSPARENT;
        visuals.extreme_bg_color = Color32::from_rgb(8, 9, 11);
        cc.egui_ctx.set_visuals(visuals);
        let mut app = App {
            monitor,
            prefs,
            sounds: Sounds::new(),
            notifier: Notifier::new(),
            scene,
            assets: Assets::new(&cc.egui_ctx),
            tray: Tray::new(&MenuState { sounds: true, sound_help: true, sound_done: true, notify: true, notify_help: true, notify_done: false, on_top: true, login: false, sessions: vec![], session: String::new(), demo: false, attention: 0 }, wake),
            chat: None,
            compose: ComposeState::default(),
            hud: HudState::default(),
            show_log: false,
            visible: true,
            first_frame: true,
            expected: None,
            commanded_at: None,
            last_size: None,
            size_changed_at: None,
            resize_start: None,
            grip: false,
            last_outer: None,
            key_panel: None,
            login,
            login_enabled,
        };
        app.monitor.refresh();
        app
    }

    fn menu_state(&self) -> MenuState {
        MenuState {
            sounds: self.prefs.sound_enabled,
            sound_help: self.prefs.sound_needs_help,
            sound_done: self.prefs.sound_finished,
            notify: self.prefs.notify_enabled,
            notify_help: self.prefs.notify_needs_help,
            notify_done: self.prefs.notify_finished,
            on_top: self.prefs.on_top,
            login: self.login_enabled,
            sessions: self.monitor.sessions.clone(),
            session: self.monitor.session.clone(),
            demo: self.monitor.demo,
            attention: self.monitor.agents.iter().filter(|a| a.status == "blocked").count(),
        }
    }

    // ---- Window geometry

    /// Columns shown: the user's, but never more than there are agents.
    fn shown_columns(&self) -> usize {
        self.prefs.columns.min(self.monitor.agents.len().max(1))
    }

    fn panel_open(&self) -> bool {
        self.monitor.composing || self.chat.is_some()
    }

    /// Height of everything that is not rooms: insets, HUD and chat panel.
    fn chrome(&self) -> f32 {
        TOP_INSET + BOTTOM_INSET + if self.panel_open() { PANEL_HEIGHT } else { 0.0 } + if self.monitor.shows_hud() { HUD_HEIGHT } else { 0.0 }
    }

    /// Height that shows the agents' rows, up to the user's row count (at
    /// least one), capped to the screen.
    fn target_height(&self, screen: Vec2) -> f32 {
        let columns = self.shown_columns();
        let needed = (self.monitor.visible_agents().len() + columns - 1) / columns;
        let shown = needed.max(1).min(self.prefs.rows) as f32;
        let wanted = self.chrome() + shown * ROW_H + (shown - 1.0) * GAP;
        let limit = screen.y - SCREEN_TOP - 2.0 * MARGIN;
        if limit > 100.0 { wanted.min(limit) } else { wanted }
    }

    fn target_width(&self) -> f32 {
        scene::width_for(self.shown_columns())
    }

    fn command_size(&mut self, ctx: &egui::Context, outer: Rect, size: Vec2, anchor_left: bool) {
        let x = if anchor_left { outer.min.x } else { outer.max.x - size.x };
        ctx.send_viewport_cmd(ViewportCommand::OuterPosition(egui::pos2(x, outer.min.y)));
        ctx.send_viewport_cmd(ViewportCommand::InnerSize(size));
        self.expected = Some(size);
        self.commanded_at = Some(Instant::now());
    }

    /// Resize the window to whole rooms. Changes in the agent count keep the
    /// top-right corner where the user put it; a resize by the user keeps
    /// the corner opposite the one dragged (the top-left for the grip).
    fn fit_size(&mut self, ctx: &egui::Context, anchor_left: bool) {
        let (outer, screen) = ctx.input(|i| (i.viewport().outer_rect, i.viewport().monitor_size));
        let Some(outer) = outer else { return };
        let screen = screen.unwrap_or(vec2(1440.0, 900.0));
        ctx.send_viewport_cmd(ViewportCommand::MinInnerSize(vec2(scene::width_for(1), self.chrome() + ROW_H)));
        if self.resize_start.is_some() { return; }
        let size = vec2(self.target_width(), self.target_height(screen));
        if (outer.width() - size.x).abs() > 0.5 || (outer.height() - size.y).abs() > 0.5 {
            self.command_size(ctx, outer, size, anchor_left);
        }
    }

    /// Put the widget back where it was, if that spot is still on the
    /// screen; otherwise in the top-right corner.
    fn restore_position(&mut self, ctx: &egui::Context) {
        let screen = ctx.input(|i| i.viewport().monitor_size).unwrap_or(vec2(1440.0, 900.0));
        let size = vec2(self.target_width(), self.target_height(screen));
        let saved = self.prefs.top_right.filter(|(x, y)| *x - 20.0 >= 0.0 && *x - 20.0 <= screen.x && *y >= 0.0 && *y + 20.0 <= screen.y);
        let (x, y) = match saved {
            Some((right, top)) => ((right - size.x).clamp(0.0, (screen.x - size.x).max(0.0)), top),
            None => (screen.x - size.x - MARGIN, SCREEN_TOP + MARGIN),
        };
        ctx.send_viewport_cmd(ViewportCommand::OuterPosition(egui::pos2(x, y)));
        ctx.send_viewport_cmd(ViewportCommand::InnerSize(size));
        self.expected = Some(size);
        self.commanded_at = Some(Instant::now());
    }

    fn anchor_to_corner(&mut self, ctx: &egui::Context) {
        self.prefs.top_right = None;
        self.prefs.save();
        self.restore_position(ctx);
    }

    /// Watch the window: a size we did not ask for is the user resizing, and
    /// once it settles it snaps to whole rooms; a move is remembered.
    fn track_window(&mut self, ctx: &egui::Context, now: f64) {
        let Some(outer) = ctx.input(|i| i.viewport().outer_rect) else { return };
        let size = outer.size();
        let settled = self.commanded_at.map(|t| t.elapsed() > Duration::from_millis(600)).unwrap_or(true);
        if let (Some(expected), Some(last)) = (self.expected, self.last_size) {
            let differs = (size.x - expected.x).abs() > 1.0 || (size.y - expected.y).abs() > 1.0;
            let moved = (size.x - last.x).abs() > 0.5 || (size.y - last.y).abs() > 0.5;
            if differs && moved && settled {
                if self.resize_start.is_none() { self.resize_start = self.last_outer; }
                self.size_changed_at = Some(now);
            }
        }
        if let (Some(start), Some(changed)) = (self.resize_start, self.size_changed_at) {
            let dragging = ctx.input(|i| i.pointer.any_down());
            if now - changed > 0.35 && !dragging {
                // Snap: the new width picks the columns, the new height the rows to
                // show before scrolling. A side left alone keeps its setting.
                if (size.x - start.width()).abs() > 1.0 {
                    self.prefs.columns = (((size.x - GAP) / (scene::ROW_W + GAP)).round() as usize).clamp(1, 8);
                }
                if (size.y - start.height()).abs() > 1.0 {
                    self.prefs.rows = (((size.y - self.chrome() + GAP) / (ROW_H + GAP)).round() as usize).max(1);
                }
                self.prefs.save();
                let anchor_left = self.grip || (outer.min.x - start.min.x).abs() < 1.0;
                self.resize_start = None;
                self.size_changed_at = None;
                self.grip = false;
                self.fit_size(ctx, anchor_left);
            }
        } else if let Some(last) = self.last_outer {
            let moved = (outer.min.x - last.min.x).abs() > 0.5 || (outer.min.y - last.min.y).abs() > 0.5;
            if moved && settled {
                self.prefs.top_right = Some((outer.max.x, outer.min.y));
                self.prefs.save();
            }
        }
        self.last_size = Some(size);
        self.last_outer = Some(outer);
    }

    // ---- Showing and hiding

    fn show(&mut self, ctx: &egui::Context) {
        self.visible = true;
        ctx.send_viewport_cmd(ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(ViewportCommand::Focus);
    }

    fn hide(&mut self, ctx: &egui::Context) {
        self.visible = false;
        ctx.send_viewport_cmd(ViewportCommand::Visible(false));
    }

    /// Show the dungeon with an agent's chat open, clearing a filter that hides it.
    fn open_agent(&mut self, ctx: &egui::Context, id: &str) {
        if !self.monitor.agents.iter().any(|a| a.id == id) { return self.show(ctx); }
        if !self.monitor.visible_agents().iter().any(|a| a.id == id) {
            self.monitor.set_filter(StatusFilter::All);
            self.monitor.set_query(String::new());
            self.prefs.filter = "all".into();
            self.prefs.save();
        }
        self.monitor.select(Some(id.to_string()));
        self.show(ctx);
    }

    fn handle_tray(&mut self, ctx: &egui::Context, action: TrayAction) {
        match action {
            TrayAction::Toggle => { if self.visible { self.hide(ctx) } else { self.show(ctx) } }
            TrayAction::Reanchor => { self.anchor_to_corner(ctx); self.show(ctx); }
            TrayAction::OnTop => {
                self.prefs.on_top = !self.prefs.on_top;
                self.prefs.save();
                ctx.send_viewport_cmd(ViewportCommand::WindowLevel(if self.prefs.on_top { egui::WindowLevel::AlwaysOnTop } else { egui::WindowLevel::Normal }));
            }
            TrayAction::Login => {
                if let Some(login) = &self.login {
                    let result = if self.login_enabled { login.disable() } else { login.enable() };
                    match result {
                        Ok(()) => self.login_enabled = !self.login_enabled,
                        Err(error) => {
                            rfd::MessageDialog::new().set_title("Herdr Pixel Dungeon").set_description(format!("{}\n{}", tr("El sistema no permitió abrir la app al iniciar sesión."), error)).show();
                        }
                    }
                }
            }
            TrayAction::Sounds => { self.prefs.sound_enabled = !self.prefs.sound_enabled; self.prefs.save(); }
            TrayAction::SoundHelp => { self.prefs.sound_needs_help = !self.prefs.sound_needs_help; self.prefs.save(); self.sounds.play(alerts::AlertKind::NeedsHelp); }
            TrayAction::SoundDone => { self.prefs.sound_finished = !self.prefs.sound_finished; self.prefs.save(); self.sounds.play(alerts::AlertKind::Finished); }
            TrayAction::Preview => self.sounds.preview(),
            TrayAction::Notify => { self.prefs.notify_enabled = !self.prefs.notify_enabled; self.prefs.save(); }
            TrayAction::NotifyHelp => { self.prefs.notify_needs_help = !self.prefs.notify_needs_help; self.prefs.save(); }
            TrayAction::NotifyDone => { self.prefs.notify_finished = !self.prefs.notify_finished; self.prefs.save(); }
            TrayAction::Session(name) => {
                if self.monitor.demo { self.monitor.set_demo(false); }
                self.monitor.set_session(&name);
                self.prefs.session = Some(name);
                self.prefs.save();
                self.chat = None;
            }
            TrayAction::Demo => { let demo = !self.monitor.demo; self.monitor.set_demo(demo); self.chat = None; }
            TrayAction::About => {
                rfd::MessageDialog::new().set_title(tr("Acerca de Herdr Pixel Dungeon")).set_description(format!("Herdr Pixel Dungeon {}\n{}", env!("CARGO_PKG_VERSION"), tr("Creado por Nacho Valencia.\nCódigo y pixel art originales · MIT."))).show();
            }
            TrayAction::Quit => ctx.send_viewport_cmd(ViewportCommand::Close),
        }
    }

    /// Ask before typing /exit into an agent's chat.
    fn confirm_finish(&mut self, id: &str) {
        let Some(agent) = self.monitor.agents.iter().find(|a| a.id == id).cloned() else { return };
        let answer = rfd::MessageDialog::new()
            .set_title(trf("¿Finalizar {}?", &[&agent.project]))
            .set_description(tr("Se escribirá /exit en su chat de Herdr."))
            .set_level(rfd::MessageLevel::Warning)
            .set_buttons(rfd::MessageButtons::OkCancelCustom(tr("Finalizar"), tr("Cancelar")))
            .show();
        if matches!(answer, rfd::MessageDialogResult::Ok | rfd::MessageDialogResult::Custom(_)) {
            if let rfd::MessageDialogResult::Custom(label) = &answer { if *label != tr("Finalizar") { return; } }
            let _ = self.monitor.finish(&agent);
        }
    }
}

impl eframe::App for App {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let now = ctx.input(|i| i.time);
        // HPD_TEST_HIDE=1: hide after 2 s and show again after 6 s, to check
        // that a hidden window still wakes up (what the tray toggle relies on).
        if std::env::var("HPD_TEST_HIDE").is_ok() {
            if now > 2.0 && now < 6.0 && self.visible { self.hide(ctx); }
            if now > 6.0 && !self.visible { self.show(ctx); }
        }
        if self.first_frame {
            self.first_frame = false;
            self.restore_position(ctx);
        }
        let mut needs_fit = self.monitor.poll();
        // Sounds and notifications for what just changed.
        let alerts: Vec<alerts::AgentAlert> = std::mem::take(&mut self.monitor.alerts);
        if let Some(first) = alerts.first() {
            if wants_sound(&self.prefs, first.kind) { self.sounds.play(first.kind); }
            self.notifier.post(&self.prefs, &alerts);
        }
        for id in self.notifier.clicked() { self.open_agent(ctx, &id); needs_fit = true; }
        for action in self.tray.poll() { self.handle_tray(ctx, action); needs_fit = true; }
        self.tray.update(&self.menu_state());
        self.track_window(ctx, now);

        // The chat panel follows the selection.
        match (&self.monitor.selected, &self.chat) {
            (Some(id), Some(chat)) if &chat.agent_id == id => {}
            (Some(id), _) => { self.chat = Some(ChatState::new(id)); needs_fit = true; }
            (None, Some(_)) => { self.chat = None; needs_fit = true; }
            (None, None) => {}
        }
        // Typing in the chat or new-agent panel needs the keyboard, but only
        // take it when one opens: later updates must not pull typing away.
        let panel = self.monitor.selected.clone().or_else(|| self.monitor.composing.then(|| "compose".to_string()));
        if panel.is_some() && panel != self.key_panel { ctx.send_viewport_cmd(ViewportCommand::Focus); }
        self.key_panel = panel;
        self.scene.set_selected(self.monitor.selected.clone());
        self.scene.empty_text = if !self.monitor.agents.is_empty() { tr("Ningún agente coincide") } else if self.monitor.error.is_some() { tr("Esperando a Herdr…") } else { tr("Sin agentes en la sesión") };
        let visible_agents = self.monitor.visible_agents();
        self.scene.sync(&visible_agents);

        let hovering = ctx.input(|i| i.pointer.hover_pos()).is_some();
        let note = connection_note(self.monitor.error.as_deref(), self.monitor.updated, Instant::now(), 5.0);
        let panel_open = self.panel_open();
        let shows_hud = self.monitor.shows_hud();

        egui::CentralPanel::default().frame(Frame::NONE).show(ctx, |ui| {
            let full = ui.max_rect();
            ui.painter().rect_filled(full, CornerRadius::same(14), BACKGROUND);
            let panel_h = if panel_open { PANEL_HEIGHT } else { 0.0 };
            let hud_h = if shows_hud { HUD_HEIGHT } else { 0.0 };
            let scene_rect = Rect::from_min_max(full.min, egui::pos2(full.max.x, full.max.y - panel_h - hud_h));
            let hud_rect = Rect::from_min_max(egui::pos2(full.min.x, scene_rect.max.y), egui::pos2(full.max.x, scene_rect.max.y + hud_h));
            let panel_rect = Rect::from_min_max(egui::pos2(full.min.x, hud_rect.max.y), full.max);
            // The dungeon.
            let response = ui.scope_builder(egui::UiBuilder::new().max_rect(scene_rect), |ui| {
                ui.set_clip_rect(scene_rect);
                self.scene.ui(ui, &self.assets, now)
            }).inner;
            if note.is_some() {
                // The last known rooms stay, faded, while the data is not live.
                ui.painter().rect_filled(scene_rect, CornerRadius { nw: 14, ne: 14, sw: 0, se: 0 }, Color32::from_rgba_unmultiplied(13, 15, 17, 90));
            }
            if let Some(id) = response.clicked {
                let next = if self.monitor.selected.as_deref() == Some(&id) { None } else { Some(id) };
                self.monitor.select(next);
            }
            if let Some(id) = response.finish { self.confirm_finish(&id); }
            // The HUD.
            if shows_hud {
                let bottom = if panel_open { 0 } else { 14 };
                ui.painter().rect_filled(hud_rect, CornerRadius { nw: 0, ne: 0, sw: bottom, se: bottom }, ui::HUD_FILL);
                ui.painter().hline(hud_rect.x_range(), hud_rect.min.y, egui::Stroke::new(1.0_f32, Color32::from_rgba_unmultiplied(255, 255, 255, 20)));
                let inner = Rect::from_min_max(egui::pos2(hud_rect.min.x + 8.0, hud_rect.min.y), egui::pos2(hud_rect.max.x - 8.0, hud_rect.max.y));
                let action = ui.scope_builder(egui::UiBuilder::new().max_rect(inner), |ui| ui::hud(ui, &mut self.monitor, &mut self.hud)).inner;
                if action.toggle_log { self.show_log = !self.show_log; }
                if action.compose { let on = !self.monitor.composing; self.monitor.set_composing(on); }
            }
            // The chat or summon panel.
            if panel_open {
                let line = if self.monitor.composing { Color32::from_rgb(140, 217, 115) } else {
                    self.chat.as_ref().and_then(|c| self.monitor.agents.iter().find(|a| a.id == c.agent_id)).map(|a| scene::agent_color(&a.status)).unwrap_or(Color32::GRAY)
                };
                ui.painter().rect_filled(panel_rect, CornerRadius { nw: 0, ne: 0, sw: 14, se: 14 }, ui::PANEL_FILL);
                ui.painter().hline(panel_rect.x_range(), panel_rect.min.y, egui::Stroke::new(1.0_f32, Color32::from_rgba_unmultiplied(line.r(), line.g(), line.b(), 180)));
                let inner = Rect::from_min_max(egui::pos2(panel_rect.min.x + 10.0, panel_rect.min.y + 8.0), egui::pos2(panel_rect.max.x - 10.0, panel_rect.max.y - 8.0));
                ui.scope_builder(egui::UiBuilder::new().max_rect(inner), |ui| {
                    ui.set_clip_rect(panel_rect);
                    if self.monitor.composing {
                        let action = ui::compose_panel(ui, &self.monitor, &mut self.prefs, &mut self.compose);
                        if action.close { self.monitor.set_composing(false); }
                    } else if let Some(chat) = &mut self.chat {
                        if let Some(agent) = self.monitor.agents.iter().find(|a| a.id == chat.agent_id).cloned() {
                            let action = ui::chat_panel(ui, &self.monitor, &agent, chat, now);
                            if action.close { self.monitor.select(None); }
                        }
                    }
                });
            }
        });

        // Overlays.
        if let Some((text, lost)) = &note { ui::connection_banner(ctx, text, *lost); }
        if hovering || self.show_log {
            let action = ui::controls(ctx, self.prefs.sound_enabled, self.show_log);
            if action.compose { let on = !self.monitor.composing; self.monitor.set_composing(on); }
            if action.log { self.show_log = !self.show_log; }
            if action.sound { self.prefs.sound_enabled = !self.prefs.sound_enabled; self.prefs.save(); }
            if action.minimize { self.hide(ctx); }
            if action.close { ctx.send_viewport_cmd(ViewportCommand::Close); }
        }
        if self.show_log && ui::activity_log(ctx, &self.monitor.events) { self.show_log = false; }
        ui::drag_handle(ctx);
        if ui::resize_grip(ctx, hovering) { self.grip = true; }

        if self.monitor.changed { self.monitor.changed = false; needs_fit = true; }
        if self.monitor.filter.raw() != self.prefs.filter { self.prefs.filter = self.monitor.filter.raw().into(); self.prefs.save(); }
        if needs_fit { self.fit_size(ctx, false); }
        ctx.request_repaint_after(Duration::from_millis(if self.visible { 33 } else { 500 }));
    }
}

/// Launch at login through a LaunchAgent (macOS) or an autostart entry (Linux).
fn login_item() -> Option<auto_launch::AutoLaunch> {
    let exe = std::env::current_exe().ok()?;
    let path = exe.to_string_lossy().to_string();
    // Inside an .app bundle, register the bundle itself.
    let app = path.find("/Contents/MacOS/").map(|at| path[..at].to_string()).unwrap_or(path);
    auto_launch::AutoLaunchBuilder::new().set_app_name("Herdr Pixel Dungeon").set_app_path(&app).set_use_launch_agent(true).build().ok()
}

/// The system's Reduce Motion setting (macOS); Linux has no common switch,
/// so HPD_REDUCE_MOTION=1 serves there.
fn reduce_motion() -> bool {
    if std::env::var("HPD_REDUCE_MOTION").map(|v| v == "1").unwrap_or(false) { return true; }
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = std::process::Command::new("defaults").args(["read", "com.apple.universalaccess", "reduceMotion"]).output() {
            return String::from_utf8_lossy(&output.stdout).trim() == "1";
        }
    }
    false
}
