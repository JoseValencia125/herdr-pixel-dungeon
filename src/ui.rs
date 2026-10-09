//! The widget's chrome around the dungeon: the HUD with state chips and
//! search, the chat panel, the "summon an agent" panel, the activity log on
//! its parchment, the connection banner, the hover controls, the drag
//! handle and the resize grip.

use crate::herdr::{Agent, MenuOptions, StatusFilter, CREATABLE_KINDS};
use crate::l10n::{tr, trf};
use crate::monitor::{GuildEvent, Monitor};
use crate::prefs::Prefs;
use crate::scene::agent_color;
use egui::{pos2, vec2, Align2, Color32, Context, CornerRadius, FontId, Frame, Key, Margin, RichText, Stroke, Ui, Vec2};
use std::sync::mpsc::Receiver;

pub const HUD_HEIGHT: f32 = 28.0;
pub const PANEL_HEIGHT: f32 = 220.0;
pub const PANEL_FILL: Color32 = Color32::from_rgb(23, 20, 28);
pub const HUD_FILL: Color32 = Color32::from_rgb(19, 17, 23);
const DIM: Color32 = Color32::from_rgb(150, 150, 155);

pub fn tint(filter: StatusFilter) -> Color32 {
    match filter {
        StatusFilter::Blocked => Color32::from_rgb(255, 69, 58),
        StatusFilter::Working => Color32::from_rgb(255, 159, 10),
        StatusFilter::Idle => Color32::from_rgb(152, 152, 157),
        StatusFilter::Done => Color32::from_rgb(48, 209, 88),
        StatusFilter::All => Color32::WHITE,
    }
}

pub fn filter_name(filter: StatusFilter) -> String {
    tr(match filter {
        StatusFilter::All => "Todos",
        StatusFilter::Blocked => "Necesita atención",
        StatusFilter::Working => "Trabajando",
        StatusFilter::Idle => "En espera",
        StatusFilter::Done => "Listo",
    })
}

fn alpha(color: Color32, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), (a * 255.0) as u8)
}

fn mono(text: &str, size: f32) -> RichText {
    RichText::new(text).font(FontId::monospace(size))
}

fn flat_button(ui: &mut Ui, text: RichText) -> egui::Response {
    ui.add(egui::Button::new(text).frame(false))
}

// ---- HUD

#[derive(Default)]
pub struct HudState {
    pub searching: bool,
    focus_search: bool,
}

pub struct HudAction {
    pub toggle_log: bool,
}

/// Bar under the rooms: one chip per state (with its count) to filter the
/// rooms, and a search box over project, harness, branch, folder and activity.
pub fn hud(ui: &mut Ui, monitor: &mut Monitor, state: &mut HudState) -> HudAction {
    let mut action = HudAction { toggle_log: false };
    ui.horizontal_centered(|ui| {
        ui.spacing_mut().item_spacing = vec2(4.0, 0.0);
        for filter in StatusFilter::ALL {
            chip(ui, monitor, filter);
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            let open = state.searching || !monitor.query.is_empty();
            let glyph = if open { "✕" } else { "🔍" };
            let button = flat_button(ui, mono(glyph, 11.0).color(alpha(Color32::WHITE, 0.75)))
                .on_hover_text(if state.searching { tr("Cerrar búsqueda (esc)") } else { tr("Buscar por proyecto, agente, rama, carpeta o actividad") });
            if button.clicked() {
                if open { monitor.set_query(String::new()); state.searching = false; } else { state.searching = true; state.focus_search = true; }
            }
            if flat_button(ui, mono("📜", 11.0).color(alpha(Color32::from_rgb(237, 214, 158), 0.85))).on_hover_text(tr("Registro de actividad")).clicked() {
                action.toggle_log = true;
            }
            if open {
                let mut query = monitor.query.clone();
                let edit = egui::TextEdit::singleline(&mut query)
                    .hint_text(tr("Buscar…"))
                    .font(FontId::monospace(11.0))
                    .desired_width(130.0)
                    .margin(Margin::symmetric(5, 2));
                let response = ui.add(edit);
                if state.focus_search { response.request_focus(); state.focus_search = false; }
                if response.has_focus() && ui.input(|i| i.key_pressed(Key::Escape)) { query.clear(); state.searching = false; }
                monitor.set_query(query);
            }
        });
    });
    action
}

fn chip(ui: &mut Ui, monitor: &mut Monitor, filter: StatusFilter) {
    let count = if filter == StatusFilter::All { monitor.agents.len() } else { monitor.agents.iter().filter(|a| filter.admits(a)).count() };
    let on = monitor.filter == filter;
    // Agents asking for help keep the chip lit red whatever the filter.
    let alarm = filter == StatusFilter::Blocked && count > 0;
    let color = tint(filter);
    let fill = if alarm { alpha(Color32::RED, if on { 0.75 } else { 0.45 }) } else if on { alpha(color, if filter == StatusFilter::All { 0.2 } else { 0.4 }) } else { alpha(Color32::BLACK, 0.35) };
    let edge = if on { alpha(Color32::WHITE, 0.7) } else if alarm { Color32::RED } else { alpha(Color32::WHITE, 0.15) };
    let ink = if alarm || on { Color32::WHITE } else { alpha(Color32::WHITE, 0.6) };
    let text = match filter {
        StatusFilter::All => format!("{} {}", tr("Todos"), count),
        StatusFilter::Blocked => format!("! {count}"),
        _ => format!("■ {count}"),
    };
    let galley = ui.painter().layout_no_wrap(text.clone(), FontId::monospace(10.0), ink);
    let size = vec2(galley.size().x + 10.0, 18.0);
    let (rect, response) = ui.allocate_exact_size(size, egui::Sense::click());
    ui.painter().rect_filled(rect, CornerRadius::same(3), fill);
    ui.painter().rect_stroke(rect, CornerRadius::same(3), Stroke::new(1.0_f32, edge), egui::StrokeKind::Inside);
    if matches!(filter, StatusFilter::Working | StatusFilter::Idle | StatusFilter::Done) {
        // The square marker in the state's colour, then the count.
        ui.painter().rect_filled(egui::Rect::from_center_size(pos2(rect.min.x + 8.0, rect.center().y), vec2(6.0, 6.0)), CornerRadius::ZERO, color);
        ui.painter().text(pos2(rect.min.x + 14.0, rect.center().y), Align2::LEFT_CENTER, count.to_string(), FontId::monospace(10.0), ink);
    } else {
        ui.painter().galley(pos2(rect.min.x + 5.0, rect.center().y - galley.size().y / 2.0), galley, ink);
    }
    let response = response.on_hover_text(filter_name(filter));
    if response.clicked() {
        monitor.set_filter(if on && filter != StatusFilter::All { StatusFilter::All } else { filter });
    }
}

// ---- Chat panel

pub struct ChatState {
    pub agent_id: String,
    draft: String,
    lines: Vec<String>,
    note: Option<String>,
    sending: Option<Receiver<Option<String>>>,
    /// Option picked with ↑/↓ or a click, into `menu.options`.
    choice: Option<usize>,
    tail_rx: Option<Receiver<Vec<String>>>,
    next_tail: f64,
    focus: bool,
    status_seen: String,
}

impl ChatState {
    pub fn new(agent_id: &str) -> ChatState {
        ChatState { agent_id: agent_id.to_string(), draft: String::new(), lines: vec![], note: None, sending: None, choice: None, tail_rx: None, next_tail: 0.0, focus: true, status_seen: String::new() }
    }

    fn menu(&self, agent: &Agent) -> MenuOptions {
        if agent.status == "blocked" { MenuOptions::new(&self.lines) } else { MenuOptions::default() }
    }

    /// Highlight an option and put its text in the box, ready to send with ⏎.
    fn pick(&mut self, menu: &MenuOptions, index: usize) {
        self.choice = Some(index);
        self.draft = menu.options[index].text.clone();
        self.focus = true;
    }

    fn run(&mut self, rx: Receiver<Option<String>>) {
        self.sending = Some(rx);
        self.note = None;
    }
}

pub struct ChatAction {
    pub close: bool,
}

/// Opens under the rooms when one is clicked: the tail of the agent's
/// terminal, quick answers for a permission prompt, and a box to type to it.
pub fn chat_panel(ui: &mut Ui, monitor: &Monitor, agent: &Agent, state: &mut ChatState, now: f64) -> ChatAction {
    let mut action = ChatAction { close: false };
    // Keep the terminal tail fresh while the panel is open.
    if state.status_seen != agent.status { state.status_seen = agent.status.clone(); state.next_tail = 0.0; }
    if now >= state.next_tail && state.tail_rx.is_none() {
        state.tail_rx = Some(monitor.tail(agent, 30));
        state.next_tail = now + 2.0;
    }
    if let Some(rx) = &state.tail_rx {
        if let Ok(lines) = rx.try_recv() {
            state.lines = lines;
            state.tail_rx = None;
            if let Some(c) = state.choice { if c >= state.menu(agent).options.len() { state.choice = None; } }
        }
    }
    if let Some(rx) = &state.sending {
        if let Ok(failure) = rx.try_recv() {
            state.sending = None;
            state.note = failure;
            state.focus = true;
            state.next_tail = now + 0.6;
            state.tail_rx = None;
        }
    }
    let sending = state.sending.is_some();
    let menu = state.menu(agent);
    let color = agent_color(&agent.status);

    // While the agent is asking something, ↑/↓ move its highlighted option
    // and ⏎ (with nothing typed) picks it, as in its own terminal.
    let (up, down, escape) = ui.input_mut(|i| {
        let plain = i.modifiers.is_none();
        (plain && i.consume_key(egui::Modifiers::NONE, Key::ArrowUp), plain && i.consume_key(egui::Modifiers::NONE, Key::ArrowDown), i.key_pressed(Key::Escape))
    });
    if escape { action.close = true; }
    if agent.status == "blocked" && (up || down) {
        let delta: i64 = if up { -1 } else { 1 };
        if !menu.options.is_empty() {
            let start = state.choice.map(|c| c as i64).or(menu.highlighted.map(|h| h as i64)).unwrap_or(if delta > 0 { -1 } else { menu.options.len() as i64 });
            let index = (start + delta).clamp(0, menu.options.len() as i64 - 1) as usize;
            state.pick(&menu, index);
        } else if !sending {
            state.run(monitor.press(&[if up { "up".to_string() } else { "down".to_string() }], agent));
        }
    }

    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing = vec2(6.0, 7.0);
        ui.horizontal(|ui| {
            let (dot, _) = ui.allocate_exact_size(vec2(8.0, 8.0), egui::Sense::hover());
            ui.painter().circle_filled(dot.center(), 4.0, color);
            ui.label(mono(&agent.name, 12.0).strong().color(Color32::WHITE));
            ui.label(mono(&format!("{} · {}", agent.project, agent.label()), 11.0).color(DIM));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if flat_button(ui, mono("✕", 12.0).color(Color32::WHITE)).on_hover_text("Cerrar (esc)").clicked() { action.close = true; }
                if flat_button(ui, mono("⧉", 13.0).color(Color32::WHITE)).on_hover_text(tr("Enfocar este agente en Herdr")).clicked() && !sending {
                    state.run(monitor.focus(agent));
                }
            });
        });
        let body_height = PANEL_HEIGHT - 16.0 - 7.0 * 2.0 - 22.0 - 24.0 - if state.note.is_some() { 16.0 } else { 0.0 };
        Frame::new().fill(alpha(Color32::BLACK, 0.45)).corner_radius(CornerRadius::same(5)).inner_margin(Margin::same(6)).show(ui, |ui| {
            ui.set_min_height(body_height.max(40.0));
            ui.set_max_height(body_height.max(40.0));
            ui.set_width(ui.available_width());
            let asking = agent.status == "blocked" && !state.lines.is_empty();
            egui::ScrollArea::vertical().auto_shrink([false, false]).stick_to_bottom(!asking).show(ui, |ui| {
                ui.spacing_mut().item_spacing = vec2(0.0, if asking { 2.0 } else { 1.0 });
                if state.lines.is_empty() {
                    ui.label(mono(&tr("Leyendo la terminal…"), 10.0).color(DIM));
                }
                let mut picked: Option<usize> = None;
                for (i, line) in state.lines.iter().enumerate() {
                    let option = menu.options.iter().position(|o| o.line == i);
                    let highlighted = option.is_some() && option == state.choice;
                    let lead = asking && i == 0 && agent.question.is_some();
                    let text = mono(line, 10.0).color(if highlighted || lead { Color32::WHITE } else { Color32::from_gray(217) });
                    let text = if highlighted || lead { text.strong() } else { text };
                    let label = egui::Label::new(text).wrap();
                    let response = if option.is_some() {
                        let frame = Frame::new().fill(if highlighted { alpha(color, 0.35) } else { Color32::TRANSPARENT }).corner_radius(CornerRadius::same(3));
                        frame.show(ui, |ui| { ui.set_width(ui.available_width()); ui.add(label.sense(egui::Sense::click())) }).inner
                    } else {
                        ui.add(label)
                    };
                    if response.clicked() { picked = option; }
                }
                if let Some(index) = picked { state.pick(&menu, index); }
            });
        });
        ui.horizontal(|ui| {
            let hint = if agent.status == "blocked" { trf("↑↓ y ⏎ eligen · o responde a {}…", &[&agent.name]) } else { trf("Escribir a {}…", &[&agent.name]) };
            let buttons_width = match agent.status.as_str() { "blocked" => 150.0, "working" => 80.0, _ => 26.0 };
            let mut draft = state.draft.clone();
            let edit = egui::TextEdit::singleline(&mut draft).hint_text(hint).font(FontId::proportional(12.0)).desired_width(ui.available_width() - buttons_width).interactive(!sending);
            let response = ui.add(edit);
            if state.focus { response.request_focus(); state.focus = false; }
            let submitted = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
            let empty = draft.trim().is_empty();
            state.draft = draft;
            if submitted && !sending {
                if agent.status == "blocked" && empty {
                    // Nothing typed: ⏎ picks the option its terminal already highlights.
                    state.run(monitor.press(&["enter".into()], agent));
                } else {
                    submit(state, monitor, agent, &menu);
                }
                state.focus = true;
            }
            if ui.add_enabled(!sending && !empty, egui::Button::new(mono("➤", 12.0)).frame(false)).on_hover_text(tr("Enviar (⏎)")).clicked() {
                submit(state, monitor, agent, &menu);
            }
            if agent.status == "blocked" {
                if ui.add_enabled(!sending, egui::Button::new(mono(&tr("Aceptar"), 11.0))).on_hover_text(tr("Elegir la opción marcada del agente (⏎ en su terminal)")).clicked() {
                    match state.choice { Some(choice) => answer(state, monitor, agent, &menu, choice), None => state.run(monitor.press(&["enter".into()], agent)) }
                }
                if ui.add_enabled(!sending, egui::Button::new(mono(&tr("Rechazar"), 11.0))).on_hover_text(tr("Cancelar la petición del agente (esc en su terminal)")).clicked() {
                    state.run(monitor.press(&["esc".into()], agent));
                }
            } else if agent.status == "working" {
                if ui.add_enabled(!sending, egui::Button::new(mono(&tr("Detener"), 11.0))).on_hover_text(tr("Interrumpir al agente (esc en su terminal)")).clicked() {
                    state.run(monitor.press(&["esc".into()], agent));
                }
            }
        });
        if let Some(note) = &state.note {
            ui.label(RichText::new(note).size(10.0).color(Color32::from_rgb(255, 159, 10)));
        }
    });
    action
}

fn submit(state: &mut ChatState, monitor: &Monitor, agent: &Agent, menu: &MenuOptions) {
    if let Some(choice) = state.choice {
        if menu.options.get(choice).map(|o| o.text == state.draft).unwrap_or(false) {
            return answer(state, monitor, agent, menu, choice);
        }
    }
    state.choice = None;
    submit_text(state, monitor, agent);
}

fn submit_text(state: &mut ChatState, monitor: &Monitor, agent: &Agent) {
    let text = state.draft.clone();
    if state.sending.is_some() || text.trim().is_empty() { return; }
    state.run(monitor.send(&text, agent));
    state.draft.clear();
}

/// Answer with an option: a terminal menu gets the arrows that reach it
/// and ⏎; a question asked in plain text gets the option's text.
fn answer(state: &mut ChatState, monitor: &Monitor, agent: &Agent, menu: &MenuOptions, index: usize) {
    if index >= menu.options.len() { return; }
    state.choice = None;
    if menu.is_menu() {
        state.run(monitor.press(&menu.keys_choosing(index), agent));
        state.draft.clear();
    } else {
        state.draft = menu.options[index].text.clone();
        submit_text(state, monitor, agent);
    }
}

// ---- New agent panel

#[derive(Default)]
pub struct ComposeState {
    pub prompt: String,
    busy: Option<Receiver<Option<String>>>,
    note: Option<String>,
}

pub struct ComposeAction {
    pub close: bool,
}

/// Opens under the rooms from the + button: pick a harness, a folder (one
/// of the agents' or any other) and an optional first prompt, and Herdr
/// starts the agent in a new workspace there.
pub fn compose_panel(ui: &mut Ui, monitor: &Monitor, prefs: &mut Prefs, state: &mut ComposeState) -> ComposeAction {
    let mut action = ComposeAction { close: false };
    if let Some(rx) = &state.busy {
        if let Ok(failure) = rx.try_recv() {
            state.busy = None;
            match failure {
                Some(failure) => state.note = Some(failure),
                None => { state.prompt.clear(); action.close = true; }
            }
        }
    }
    let busy = state.busy.is_some();
    // Folders the current agents work in, most common first.
    let mut known: Vec<String> = vec![];
    for agent in &monitor.agents {
        let path = crate::herdr::expand_home(&agent.cwd);
        if !known.contains(&path) { known.push(path); }
    }
    if prefs.create_folder.is_empty() { if let Some(first) = known.first() { prefs.create_folder = first.clone(); prefs.save(); } }
    if ui.input(|i| i.key_pressed(Key::Escape)) { action.close = true; }
    let green = Color32::from_rgb(140, 217, 115);
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing = vec2(6.0, 7.0);
        ui.horizontal(|ui| {
            ui.label(mono("+", 14.0).color(green));
            ui.label(mono(&tr("Invocar un agente"), 12.0).strong().color(Color32::WHITE));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if flat_button(ui, mono("✕", 12.0).color(Color32::WHITE)).on_hover_text(tr("Cerrar")).clicked() { action.close = true; }
            });
        });
        ui.horizontal(|ui| {
            let mut kind = prefs.create_kind.clone();
            egui::ComboBox::from_id_salt("kind").selected_text(mono(&kind, 11.0)).width(96.0).show_ui(ui, |ui| {
                for option in CREATABLE_KINDS { ui.selectable_value(&mut kind, option.to_string(), option); }
            });
            if kind != prefs.create_kind { prefs.create_kind = kind; prefs.save(); }
            let shown = if prefs.create_folder.is_empty() { tr("Carpeta…") } else { crate::herdr::abbreviate_home(&prefs.create_folder) };
            let mut folder = prefs.create_folder.clone();
            let mut choose = false;
            egui::ComboBox::from_id_salt("folder").selected_text(mono(&shown, 11.0)).width(ui.available_width() - 8.0).show_ui(ui, |ui| {
                for path in &known { ui.selectable_value(&mut folder, path.clone(), crate::herdr::abbreviate_home(path)); }
                if !known.is_empty() { ui.separator(); }
                if ui.button(tr("Elegir carpeta…")).clicked() { choose = true; }
            });
            if choose {
                let mut dialog = rfd::FileDialog::new();
                if !folder.is_empty() { dialog = dialog.set_directory(&folder); }
                if let Some(picked) = dialog.pick_folder() { folder = picked.to_string_lossy().to_string(); }
            }
            if folder != prefs.create_folder { prefs.create_folder = folder; prefs.save(); }
        });
        Frame::new().fill(alpha(Color32::BLACK, 0.45)).corner_radius(CornerRadius::same(5)).inner_margin(Margin::same(3)).show(ui, |ui| {
            let height = PANEL_HEIGHT - 16.0 - 7.0 * 3.0 - 22.0 - 24.0 - 24.0;
            ui.set_width(ui.available_width());
            let edit = egui::TextEdit::multiline(&mut state.prompt).hint_text(tr("Primer prompt (opcional)")).font(FontId::monospace(11.0)).desired_rows(4).frame(false).desired_width(f32::INFINITY).interactive(!busy);
            ui.add_sized(vec2(ui.available_width(), height.max(40.0)), edit);
        });
        ui.horizontal(|ui| {
            if busy {
                ui.spinner();
                ui.label(RichText::new(tr("Invocando…")).size(10.0).color(DIM));
            } else if let Some(note) = &state.note {
                ui.label(RichText::new(note).size(10.0).color(Color32::from_rgb(255, 159, 10)));
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let shortcut = ui.input(|i| i.modifiers.command && i.key_pressed(Key::Enter));
                let can = !busy && !prefs.create_folder.is_empty();
                if (ui.add_enabled(can, egui::Button::new(mono(&tr("Invocar"), 11.0))).on_hover_text(tr("Crear el agente (⌘⏎)")).clicked() || (shortcut && can)) && state.busy.is_none() {
                    state.note = None;
                    state.busy = Some(monitor.create(&prefs.create_kind, &prefs.create_folder, &state.prompt));
                }
            });
        });
    });
    action
}

// ---- Activity log

/// The guild's activity log on a parchment: who joined or left, state
/// changes, subagents and messages you sent, newest first, with the time.
/// Returns true when its close button was clicked.
pub fn activity_log(ctx: &Context, events: &[GuildEvent]) -> bool {
    let ink = Color32::from_rgb(61, 38, 20);
    let mut close = false;
    egui::Area::new(egui::Id::new("activity-log")).anchor(Align2::RIGHT_TOP, vec2(-8.0, 38.0)).order(egui::Order::Foreground).show(ctx, |ui| {
        Frame::new()
            .fill(Color32::from_rgb(237, 217, 168))
            .stroke(Stroke::new(2.0_f32, Color32::from_rgb(115, 74, 36)))
            .corner_radius(CornerRadius::same(4))
            .inner_margin(Margin::same(10))
            .shadow(egui::epaint::Shadow { offset: [0, 2], blur: 6, spread: 0, color: alpha(Color32::BLACK, 0.5) })
            .show(ui, |ui| {
                ui.set_width(260.0);
                ui.spacing_mut().item_spacing = vec2(5.0, 6.0);
                ui.horizontal(|ui| {
                    ui.label(mono(&tr("Registro de la guild"), 12.0).strong().color(ink));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if flat_button(ui, mono("✕", 10.0).strong().color(ink)).on_hover_text(tr("Cerrar")).clicked() { close = true; }
                    });
                });
                let line = ui.available_rect_before_wrap();
                ui.painter().hline(line.x_range(), line.min.y, Stroke::new(1.0_f32, alpha(ink, 0.35)));
                ui.add_space(2.0);
                if events.is_empty() {
                    ui.label(mono(&tr("Aún no pasa nada."), 10.0).color(alpha(ink, 0.7)));
                } else {
                    egui::ScrollArea::vertical().max_height(200.0).auto_shrink([false, true]).show(ui, |ui| {
                        ui.spacing_mut().item_spacing = vec2(5.0, 4.0);
                        for event in events {
                            ui.horizontal_top(|ui| {
                                ui.label(mono(&event.at.format("%H:%M:%S").to_string(), 10.0).color(alpha(ink, 0.6)));
                                let (dot, _) = ui.allocate_exact_size(vec2(6.0, 12.0), egui::Sense::hover());
                                ui.painter().rect_filled(egui::Rect::from_center_size(pos2(dot.center().x, dot.center().y + 1.0), vec2(6.0, 6.0)), CornerRadius::ZERO, tone_color(event.tone));
                                ui.add(egui::Label::new(mono(&event.text, 10.0).color(ink)).wrap());
                            });
                        }
                    });
                }
            });
    });
    close
}

fn tone_color(tone: &str) -> Color32 {
    match tone {
        "blocked" => Color32::RED,
        "working" => Color32::from_rgb(255, 159, 10),
        "done" | "joined" => Color32::from_rgb(38, 153, 64),
        "left" | "idle" => Color32::GRAY,
        "subagents" => Color32::from_rgb(160, 60, 180),
        "message" => Color32::from_rgb(40, 110, 230),
        _ => Color32::from_rgb(115, 74, 36),
    }
}

// ---- Connection banner

/// A pixel banner over the rooms while Herdr is unreachable or the data is
/// stale; reconnection keeps being retried in the background.
pub fn connection_banner(ctx: &Context, text: &str, lost: bool) {
    egui::Area::new(egui::Id::new("connection")).anchor(Align2::CENTER_TOP, vec2(0.0, 16.0)).order(egui::Order::Foreground).interactable(false).show(ctx, |ui| {
        let fill = if lost { Color32::from_rgb(153, 31, 36) } else { Color32::from_rgb(140, 92, 20) };
        Frame::new().fill(alpha(fill, 0.95)).stroke(Stroke::new(2.0_f32, alpha(Color32::BLACK, 0.6))).corner_radius(CornerRadius::same(3)).inner_margin(Margin::symmetric(8, 3)).show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(mono(if lost { "⚡" } else { "⌛" }, 11.0).color(Color32::WHITE));
                ui.label(mono(text, 10.0).strong().color(Color32::WHITE));
            });
        })
        .response
        .on_hover_text(if lost { tr("Reintentando la conexión automáticamente.") } else { tr("Herdr no ha entregado datos nuevos.") });
    });
}

// ---- Controls, drag handle, grip

pub struct ControlAction {
    pub compose: bool,
    pub log: bool,
    pub sound: bool,
    pub minimize: bool,
    pub close: bool,
}

/// The buttons that appear at the top-right on hover.
pub fn controls(ctx: &Context, sounds_on: bool, log_open: bool) -> ControlAction {
    let mut action = ControlAction { compose: false, log: false, sound: false, minimize: false, close: false };
    egui::Area::new(egui::Id::new("controls")).anchor(Align2::RIGHT_TOP, vec2(-6.0, 6.0)).order(egui::Order::Foreground).show(ctx, |ui| {
        Frame::new().fill(alpha(Color32::BLACK, 0.35)).corner_radius(CornerRadius::same(12)).inner_margin(Margin::symmetric(7, 3)).show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing = vec2(7.0, 0.0);
                if flat_button(ui, mono("+", 15.0).strong().color(Color32::from_rgb(140, 217, 115))).on_hover_text(tr("Invocar un agente nuevo")).clicked() { action.compose = true; }
                if flat_button(ui, mono("📜", 12.0).color(alpha(Color32::from_rgb(237, 214, 158), if log_open { 1.0 } else { 0.85 }))).on_hover_text(tr("Registro de actividad")).clicked() { action.log = true; }
                let speaker = if sounds_on { "♪" } else { "♪̸" };
                if flat_button(ui, mono(speaker, 13.0).color(alpha(Color32::WHITE, if sounds_on { 0.85 } else { 0.45 }))).on_hover_text(if sounds_on { tr("Silenciar sonidos") } else { tr("Activar sonidos") }).clicked() { action.sound = true; }
                if flat_button(ui, mono("–", 15.0).strong().color(Color32::from_rgb(250, 189, 46))).on_hover_text(tr("Minimizar (ocultar)")).clicked() { action.minimize = true; }
                if flat_button(ui, mono("✕", 13.0).strong().color(Color32::from_rgb(242, 84, 77))).on_hover_text(tr("Cerrar")).clicked() { action.close = true; }
            });
        });
    });
    action
}

/// Grab bar centred at the top of the widget: dragging it moves the window.
pub fn drag_handle(ctx: &Context) {
    egui::Area::new(egui::Id::new("drag-handle")).anchor(Align2::CENTER_TOP, Vec2::ZERO).order(egui::Order::Foreground).show(ctx, |ui| {
        let (rect, response) = ui.allocate_exact_size(vec2(160.0, 14.0), egui::Sense::drag());
        let hovering = response.hovered() || response.dragged();
        let width = if hovering { 64.0 } else { 48.0 };
        let bar = egui::Rect::from_center_size(pos2(rect.center().x, rect.min.y + 7.0), vec2(width, 5.0));
        ui.painter().rect_filled(bar.translate(vec2(0.0, 1.0)), CornerRadius::same(3), alpha(Color32::BLACK, 0.6));
        ui.painter().rect_filled(bar, CornerRadius::same(3), alpha(Color32::WHITE, if hovering { 0.75 } else { 0.35 }));
        if response.drag_started() { ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag); }
        response.on_hover_text(tr("Arrastrar para mover"));
    });
}

/// Pixel grip in the bottom-right corner: drag it to resize the widget.
pub fn resize_grip(ctx: &Context, visible: bool) -> bool {
    let mut started = false;
    egui::Area::new(egui::Id::new("resize-grip")).anchor(Align2::RIGHT_BOTTOM, vec2(-2.0, -2.0)).order(egui::Order::Foreground).show(ctx, |ui| {
        let (rect, response) = ui.allocate_exact_size(vec2(14.0, 14.0), egui::Sense::drag());
        if visible || response.hovered() {
            // Three steps of pixels down the diagonal.
            for (x, y) in [(10.0, 2.0), (6.0, 2.0), (10.0, 6.0), (2.0, 2.0), (6.0, 6.0), (10.0, 10.0)] {
                ui.painter().rect_filled(egui::Rect::from_min_size(pos2(rect.min.x + x, rect.max.y - y - 2.0), vec2(2.0, 2.0)), CornerRadius::ZERO, alpha(Color32::WHITE, 0.55));
            }
        }
        if response.drag_started() {
            ctx.send_viewport_cmd(egui::ViewportCommand::BeginResize(egui::ResizeDirection::SouthEast));
            started = true;
        }
    });
    started
}
