//! The checks `--self-test` and `cargo test` run: everything that works
//! without a window.

use crate::alerts::*;
use crate::assets::{decode_png, HEROES_PNG, ROOM_FILES};
use crate::herdr::*;
use crate::l10n;
use crate::monitor::Monitor;
use crate::prefs::Prefs;
use crate::scene::{columns_fitting, width_for, STYLES};
use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime};

fn agent(id: &str, name: &str, status: &str, project: &str, activity: &str, cwd: &str) -> Agent {
    Agent::new(id, name, status, project, activity, cwd)
}

pub fn run() {
    let sample = br#"{"result":{"snapshot":{"agents":[{"pane_id":"a","agent":"claude","agent_status":"idle","workspace_id":"w"},{"pane_id":"b","agent":"codex","agent_status":"blocked"},{"pane_id":"shell"}],"workspaces":[{"workspace_id":"w","label":"Example"}]}}}"#;
    let agents = decode_snapshot(sample).expect("snapshot");
    assert!(agents.len() == 2 && agents[0].status == "blocked" && agents[1].project == "Example");
    assert!(decode_snapshot(b"{}").is_err(), "Invalid snapshot accepted");
    assert!(decode_snapshot(br#"{"result":{"snapshot":{"agents":[]}}}"#).unwrap().is_empty());
    let mut monitor = Monitor::new("default".into(), StatusFilter::All);
    monitor.apply(demo_agents(0));
    monitor.apply(demo_agents(10));
    assert!(monitor.events.iter().any(|e| e.text.contains(&l10n::tr("Necesita atención"))));
    monitor.apply(vec![]);
    assert!(monitor.agents.is_empty());
    for (name, bytes) in ROOM_FILES { assert!(decode_png(bytes).is_some(), "Unreadable asset: {name}"); }
    let heroes = decode_png(HEROES_PNG).expect("heroes sheet");
    assert_eq!(heroes.size, [48, HERO_ORDER.len() * 32], "Hero sheet layout mismatch");
    for style in STYLES { assert!(ROOM_FILES.iter().any(|(n, _)| *n == style.background), "Missing room art: {}", style.background); }
    let busy = agent("x", "claude", "idle", "p", "a", "~").with_subagents(2);
    assert!(busy.status == "working" && busy.subagents == 2);
    assert_eq!(agent("x", "claude", "blocked", "p", "a", "~").with_subagents(1).status, "blocked");
    let repo = std::env::temp_dir().join(format!("hpd-selftest-{}", std::process::id()));
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    std::fs::create_dir_all(repo.join("src")).unwrap();
    std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/feature/x\n").unwrap();
    assert_eq!(git_branch(&repo.join("src").to_string_lossy()).as_deref(), Some("feature/x"));
    let _ = std::fs::remove_dir_all(&repo);
    assert!(harness_for("claude") == "claude" && harness_for("Codex CLI") == "codex" && harness_for("opencode") == "hero");
    let with_session = decode_snapshot(br#"{"result":{"snapshot":{"agents":[{"pane_id":"a","agent":"claude","agent_session":{"kind":"id","value":"s-1"}}]}}}"#).unwrap();
    assert!(with_session[0].session.as_deref() == Some("s-1") && with_session[0].subagents == 0);
    assert!(tool_action("WebSearch") == "read" && tool_action("Edit") == "forge" && tool_action("Bash") == "brew" && tool_action("Task") == "summon" && tool_action("TodoWrite") == "plan" && tool_action("mcp__x") == "type");
    let tail = concat!(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"Grep","input":{}}]}}"#, "\n", r#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#);
    assert_eq!(last_action(tail).as_deref(), Some("read"));
    assert_eq!(last_action(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#).as_deref(), Some("type"));
    assert_eq!(last_action(""), None);
    for (spanish, row) in l10n::TABLE.iter() {
        assert!(row.iter().all(|t| !t.is_empty()), "Missing translation: {spanish}");
        for language in l10n::LANGUAGES {
            let t = l10n::text(spanish, language);
            assert_eq!(t.matches("{}").count(), spanish.matches("{}").count(), "Format mismatch: {spanish} [{language}]");
        }
    }
    assert!(l10n::text("LISTO", "fr") == "TERMINÉ" && l10n::text("LISTO", "es") == "LISTO");
    let mut before: HashMap<String, Agent> = HashMap::new();
    before.insert("a".into(), agent("a", "claude", "working", "p", "a", "~"));
    assert_eq!(alert_for(&before, &[agent("a", "claude", "idle", "p", "a", "~")]), Some(AlertKind::Finished));
    assert_eq!(alert_for(&before, &[agent("a", "claude", "blocked", "p", "a", "~"), agent("b", "x", "done", "p", "a", "~")]), Some(AlertKind::NeedsHelp));
    before.insert("a".into(), agent("a", "claude", "idle", "p", "a", "~"));
    assert_eq!(alert_for(&before, &[agent("a", "claude", "idle", "p", "a", "~")]), None);
    let mut watcher = Monitor::new("default".into(), StatusFilter::All);
    watcher.apply(demo_agents(0));
    watcher.apply(demo_agents(10));
    assert_eq!(watcher.alerts.iter().map(|a| a.kind).collect::<Vec<_>>(), vec![AlertKind::NeedsHelp]);
    watcher.select(Some("demo:1".into()));
    watcher.apply(vec![]);
    assert!(watcher.selected.is_none());
    let path = std::env::temp_dir().join(format!("hpd-prefs-{}.json", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let mut prefs = Prefs::load(path.clone());
    assert!(wants_sound(&prefs, AlertKind::NeedsHelp) && wants_sound(&prefs, AlertKind::Finished));
    prefs.sound_finished = false;
    prefs.save();
    let reread = Prefs::load(path.clone());
    assert!(wants_sound(&reread, AlertKind::NeedsHelp) && !wants_sound(&reread, AlertKind::Finished));
    prefs.sound_enabled = false;
    prefs.save();
    assert!(!wants_sound(&Prefs::load(path.clone()), AlertKind::NeedsHelp));
    let _ = std::fs::remove_file(&path);
    let mut notes = Prefs::load(path.clone());
    assert!(wants_notification(&notes, AlertKind::NeedsHelp) && !wants_notification(&notes, AlertKind::Finished));
    notes.notify_finished = true;
    notes.notify_needs_help = false;
    notes.save();
    let reread = Prefs::load(path.clone());
    assert!(wants_notification(&reread, AlertKind::Finished) && !wants_notification(&reread, AlertKind::NeedsHelp));
    notes.notify_enabled = false;
    notes.save();
    assert!(!wants_notification(&Prefs::load(path.clone()), AlertKind::Finished));
    let _ = std::fs::remove_file(&path);
    let mut previous = HashMap::new();
    previous.insert("a".to_string(), agent("a", "x", "working", "p", "", "~"));
    previous.insert("b".to_string(), agent("b", "y", "working", "p", "", "~"));
    let both = alerts_for(&previous, &[agent("a", "x", "done", "p", "", "~"), agent("b", "y", "blocked", "p", "", "~")]);
    assert_eq!(both.iter().map(|a| a.kind).collect::<Vec<_>>(), vec![AlertKind::NeedsHelp, AlertKind::Finished]);
    assert_eq!(both.iter().map(|a| a.agent.id.as_str()).collect::<Vec<_>>(), vec!["b", "a"]);
    assert!(jingle(&[(440.0, 0.1)], SAMPLE_RATE, 0.12).len() > 1000, "Jingle did not render");
    let screen = "✻ Worked for 17s · done 12:00 AM\n※ recap: Estamos mejorando el dungeon y ya sale un cuadro\n  nueva: subir tus commits de main en un PR\n────────\n❯ la 1, con PR borrador\n────────\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents";
    assert!(meaningful_lines(screen).is_empty(), "Chrome left in terminal tail: {:?}", meaningful_lines(screen));
    assert_eq!(meaningful_lines(" Do you want to proceed?\n❯ 1. Yes\n  2. No\n❯ hola").len(), 3, "Permission options were dropped");
    let ask = "Lo que veo:\n- algo\n\nneeds input: ¿para qué es la rama nueva? Opciones:\n\n1. **Rama de PR** desde `main`\n2. Renombrar";
    assert_eq!(question_lines(ask, Some("¿para qué es la rama nueva? Opciones:")), vec!["¿para qué es la rama nueva? Opciones:", "1. Rama de PR desde main", "2. Renombrar"], "Question not cut at the ask");
    let split = concat!(r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Primera parte"}]}}"#, "\n",
                        r#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#, "\n",
                        r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Segunda parte"}]}}"#);
    assert_eq!(last_assistant_text(split).as_deref(), Some("Primera parte\nSegunda parte"), "Split assistant message not joined");
    assert_eq!(last_assistant_text(r#"{"type":"assistant","message":{"content":[{"type":"text","text":"solo"}]}}"#).as_deref(), Some("solo"));
    let job = BackgroundJob { state: "blocked".into(), needs: Some("¿Sí?".into()), transcript: Some("/t.jsonl".into()), updated: SystemTime::now() };
    let asked = agent("q", "claude", "idle", "p", "a", "~").with_jobs(&[job]);
    assert!(asked.status == "blocked" && asked.question.as_deref() == Some("¿Sí?") && asked.question_transcript.as_deref() == Some("/t.jsonl"));
    let lines: Vec<String> = ["Bash(rm -rf build)", " Do you want to proceed?", "❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No, and tell Claude what to do"].iter().map(|s| s.to_string()).collect();
    let menu = MenuOptions::new(&lines);
    assert!(menu.options.iter().map(|o| o.number).collect::<Vec<_>>() == vec![1, 2, 3] && menu.highlighted == Some(0) && menu.is_menu() && menu.options[1].text == "Yes, and don't ask again" && menu.options[2].line == 4);
    assert!(menu.keys_choosing(2) == vec!["down", "down", "enter"] && menu.keys_choosing(0) == vec!["enter"]);
    let plain_lines: Vec<String> = ["¿Qué rama?", "1. Rama de PR", "2) Renombrar", "texto", "1. Otra pregunta", "2. Sí"].iter().map(|s| s.to_string()).collect();
    let plain = MenuOptions::new(&plain_lines);
    assert!(!plain.is_menu() && plain.options.iter().map(|o| o.text.as_str()).collect::<Vec<_>>() == vec!["Otra pregunta", "Sí"] && MenuOptions::new(&["hola".to_string()]).options.is_empty());
    let pool = vec![agent("1", "claude", "blocked", "Web Shop", "Arreglando el carrito", "~/code/shop"), agent("2", "codex", "working", "API", "Tests", "~/code/api")];
    let mut branched = pool[1].clone();
    branched.branch = Some("feature/pagos".into());
    let ids = |v: Vec<Agent>| v.into_iter().map(|a| a.id).collect::<Vec<_>>();
    assert!(filter_agents(&pool, StatusFilter::All, "").len() == 2 && ids(filter_agents(&pool, StatusFilter::Blocked, "")) == vec!["1"] && filter_agents(&pool, StatusFilter::Idle, "").is_empty());
    assert!(ids(filter_agents(&pool, StatusFilter::All, "CARRITO")) == vec!["1"] && ids(filter_agents(&pool, StatusFilter::All, "codex")) == vec!["2"] && ids(filter_agents(&pool, StatusFilter::All, "web shop")) == vec!["1"]);
    assert!(ids(filter_agents(&[pool[0].clone(), branched], StatusFilter::All, "pagos")) == vec!["2"] && ids(filter_agents(&pool, StatusFilter::All, "cárrito shop")) == vec!["1"] && filter_agents(&pool, StatusFilter::Working, "shop").is_empty());
    let now = Instant::now();
    assert!(connection_note(None, Some(now), now, 5.0).is_none() && connection_note(None, None, now, 5.0).is_none());
    let stale = connection_note(None, Some(now - Duration::from_secs(14)), now, 5.0).unwrap();
    assert!(!stale.1 && stale.0.contains("14"));
    let lost = connection_note(Some("x"), Some(now - Duration::from_secs(200)), now, 5.0).unwrap();
    assert!(lost.1 && lost.0.contains('3'));
    assert_eq!(connection_note(Some("x"), None, now, 5.0).unwrap().0, l10n::tr("Herdr desconectado"));
    for n in 1..=6 { assert!(columns_fitting(width_for(n)) == n && columns_fitting(width_for(n) + 100.0) == n, "Flex wrap columns: {n}"); }
    assert!(columns_fitting(10.0) == 1 && width_for(2) == 458.0);
    let listed = decode_sessions(br#"{"sessions":[{"default":true,"name":"default","running":true},{"name":"work","running":false}]}"#);
    assert!(listed == vec![HerdrSession { name: "default".into(), running: true }, HerdrSession { name: "work".into(), running: false }] && decode_sessions(b"nope").is_empty());
    let named = agent_name("codex", "Mi Proyecto_2");
    assert!(named.starts_with("codex-mi-proyecto-2-") && named.len() == 24, "Agent name: {named}");
    assert!(root_pane(br#"{"result":{"root_pane":{"pane_id":"w3:p1"},"tab":{}}}"#).as_deref() == Some("w3:p1") && root_pane(b"{}").is_none());
    let codex = [
        r#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"rg --files app\"}"}}"#,
        r#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"npm test\"}"}}"#,
        r#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin"}}"#,
        r#"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
    ];
    assert!(codex_action(codex[0]).as_deref() == Some("read") && codex_action(codex[1]).as_deref() == Some("brew") && codex_action(&codex[0..3].join("\n")).as_deref() == Some("forge"));
    assert!(codex_action(&codex.join("\n")).as_deref() == Some("type") && codex_action(r#"{"type":"event_msg","payload":{"type":"token_count"}}"#).is_none());
    let kiro = r#"{"version":"v1","kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"x"},{"kind":"toolUse","data":{"name":"shell","input":{}}}]}}"#;
    assert!(kiro_action(kiro).as_deref() == Some("brew") && kiro_action(r#"{"kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"hola"}]}}"#).as_deref() == Some("type") && kiro_action(r#"{"kind":"Prompt","data":{}}"#).is_none());
    assert!(shell_action("/usr/bin/sed -n 1,5p x") == "read" && shell_action("swift build") == "brew" && shell_action("") == "brew");
    let mut live = vec![agent("a", "claude", "working", "p", "x", "~"), agent("b", "codex", "idle", "p", "y", "~")];
    let names: HashMap<String, String> = HashMap::new();
    let ev = |s: &str| serde_json::from_str::<serde_json::Value>(s).unwrap();
    assert!(apply_herdr_event(&ev(r#"{"event":"pane.agent_status_changed","data":{"pane_id":"b","workspace_id":"w","agent_status":"blocked"}}"#), &mut live, &names) == EventEffect::Changed && live.iter().map(|a| a.id.as_str()).collect::<Vec<_>>() == vec!["b", "a"] && live[0].status == "blocked");
    assert!(apply_herdr_event(&ev(r#"{"event":"pane_agent_status_changed","data":{"pane_id":"b","agent_status":"blocked"}}"#), &mut live, &names) == EventEffect::None);
    assert!(apply_herdr_event(&ev(r#"{"event":"pane.agent_status_changed","data":{"pane_id":"zz","agent_status":"idle"}}"#), &mut live, &names) == EventEffect::Resync);
    let mut web = HashMap::new();
    web.insert("w".to_string(), "Web".to_string());
    assert!(apply_herdr_event(&ev(r#"{"event":"pane_updated","data":{"pane":{"pane_id":"a","agent":"claude","agent_status":"done","workspace_id":"w","terminal_title_stripped":"Nuevo"}}}"#), &mut live, &web) == EventEffect::Changed);
    let a = live.iter().find(|x| x.id == "a").unwrap();
    assert!(a.activity == "Nuevo" && a.project == "Web");
    assert!(apply_herdr_event(&ev(r#"{"event":"pane_updated","data":{"pane":{"pane_id":"a","agent_status":"idle"}}}"#), &mut live, &names) == EventEffect::Changed && live.iter().map(|a| a.id.as_str()).collect::<Vec<_>>() == vec!["b"]);
    assert!(apply_herdr_event(&ev(r#"{"event":"pane_created","data":{"pane":{"pane_id":"n","agent":"kiro"}}}"#), &mut live, &names) == EventEffect::Resync);
    assert!(apply_herdr_event(&ev(r#"{"event":"pane_closed","data":{"pane_id":"b"}}"#), &mut live, &names) == EventEffect::Changed && live.is_empty());
    assert!(apply_herdr_event(&ev(r#"{"event":"pane_agent_detected","data":{"pane_id":"q"}}"#), &mut live, &names) == EventEffect::Resync && apply_herdr_event(&ev(r#"{"event":"pane_focused","data":{}}"#), &mut live, &names) == EventEffect::None);
    let subs = herdr_subscriptions(&["w2:p1".to_string(), "w1:p1".to_string()]);
    assert!(subs.last().and_then(|s| s.get("pane_id")).and_then(|v| v.as_str()) == Some("w2:p1") && subs.iter().any(|s| s.get("type").and_then(|v| v.as_str()) == Some("pane.closed")));
    assert!(herdr_error(br#"{"error":{"code":"agent_blocked","message":"blocked"},"id":"x"}"#).and_then(|e| e.code().map(str::to_string)).as_deref() == Some("agent_blocked") && herdr_error(b"oops").is_none());
    let mut ordering = Monitor::new("default".into(), StatusFilter::All);
    let urgent = agent("b", "claude", "working", "p", "", "~").with_jobs(&[BackgroundJob { state: "blocked".into(), needs: None, transcript: None, updated: SystemTime::now() }]);
    ordering.apply(vec![agent("a", "claude", "idle", "p", "", "~"), urgent]);
    assert_eq!(ordering.agents.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), vec!["b", "a"], "Attention must lead the grid");
    let daemon = std::env::temp_dir().join(format!("hpd-daemon-{}", std::process::id()));
    std::fs::create_dir_all(daemon.join("d1/pty")).unwrap();
    std::fs::write(daemon.join("d1/pty/abc123.sock"), b"").unwrap();
    let ids_found = live_job_ids(&daemon.to_string_lossy()).unwrap();
    assert!(ids_found.len() == 1 && ids_found.contains("abc123") && live_job_ids(&format!("{}-missing", daemon.to_string_lossy())).is_none(), "Live job sockets");
    let _ = std::fs::remove_dir_all(&daemon);
    assert!(natural_cmp("w2:p1", "w10:p1") == std::cmp::Ordering::Less && natural_cmp("a", "A") == std::cmp::Ordering::Equal);
    assert_eq!(l10n::trf("Tú → {}: {}", &[&"a", &"b"]), l10n::text("Tú → {}: {}", &l10n::CURRENT).replacen("{}", "a", 1).replacen("{}", "b", 1));
    println!("PASS: snapshot states, filtering, empty/error handling, monitor transitions, room art, heroes, subagent sessions, subagents keep agents busy, tool actions, translations, git branch, sound alerts + prefs, notifications + prefs, chat selection, question options, filters and search, connection notes, flex-wrap columns, sessions, agent creation, codex + kiro actions, herdr events, question extraction, Herdr error codes, live background jobs, natural order, {} bundled sprites", ROOM_FILES.len() + 1);
}

#[cfg(test)]
mod tests {
    #[test]
    fn self_test() {
        super::run();
    }
}
