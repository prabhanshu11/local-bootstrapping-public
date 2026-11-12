use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::Duration;

use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
    MouseButton, MouseEventKind,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::ExecutableCommand;
use ratatui::prelude::*;
use ratatui::widgets::*;

// ── Monitor info ─────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct Monitor {
    name: String,
    width: u64,
    height: u64,
    refresh: f64,
    x: i64,
    y: i64,
    scale: f64,
    focused: bool,
    disabled: bool,
    mirror_of: Option<String>,
    available_modes: Vec<String>,
}

fn get_monitors() -> Vec<Monitor> {
    let output = Command::new("hyprctl")
        .args(["monitors", "all", "-j"])
        .output()
        .expect("Failed to run hyprctl monitors -j");

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("Failed to parse hyprctl output");

    let arr = json.as_array().expect("Expected array from hyprctl");
    arr.iter()
        .map(|m| Monitor {
            name: m["name"].as_str().unwrap_or("").to_string(),
            width: m["width"].as_u64().unwrap_or(0),
            height: m["height"].as_u64().unwrap_or(0),
            refresh: m["refreshRate"].as_f64().unwrap_or(0.0),
            x: m["x"].as_i64().unwrap_or(0),
            y: m["y"].as_i64().unwrap_or(0),
            scale: m["scale"].as_f64().unwrap_or(1.0),
            focused: m["focused"].as_bool().unwrap_or(false),
            disabled: m["disabled"].as_bool().unwrap_or(false),
            mirror_of: m["mirrorOf"]
                .as_str()
                .filter(|s| !s.is_empty() && *s != "none")
                .map(str::to_string),
            available_modes: m["availableModes"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect()
}

fn find_primary(monitors: &[Monitor]) -> Option<&Monitor> {
    // Primary = eDP-1 (laptop), or the focused one, or first
    monitors
        .iter()
        .find(|m| m.name.starts_with("eDP"))
        .or_else(|| monitors.iter().find(|m| m.focused))
        .or(monitors.first())
}

fn monitor_logical_width(monitor: &Monitor) -> i64 {
    let w = if monitor.width == 0 { 1920 } else { monitor.width };
    (w as f64 / monitor.scale.max(0.1)) as i64
}

fn monitor_logical_height(monitor: &Monitor) -> i64 {
    let h = if monitor.height == 0 { 1080 } else { monitor.height };
    (h as f64 / monitor.scale.max(0.1)) as i64
}

fn home_config_path(file_name: &str) -> Option<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".config").join("hypr").join(file_name))
}

// "2560x1440@99.95" — the PINNED mode string used in monitor configs.
fn mode_string(m: &Monitor) -> String {
    format!("{}x{}@{:.2}", m.width, m.height, m.refresh)
}

// Parse "2560x1440@99.95Hz" (hyprctl availableModes entry) into (w, h, rr).
fn parse_mode(s: &str) -> Option<(u64, u64, f64)> {
    let s = s.trim().trim_end_matches("Hz");
    let (res, rr) = s.split_once('@')?;
    let (w, h) = res.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?, rr.parse().ok()?))
}

// ── hyprctl helpers ──────────────────────────────────────────────────

fn hyprctl(args: &[&str]) {
    let _ = Command::new("hyprctl").args(args).output();
}

fn hyprctl_batch(commands: &[String]) {
    // hyprctl --batch "cmd1 ; cmd2 ; ..."
    let batch = commands.join(" ; ");
    let _ = Command::new("hyprctl").args(["--batch", &batch]).output();
}

fn monitor_config(monitor: &Monitor) -> String {
    if monitor.disabled {
        return format!("{},disabled", monitor.name);
    }
    if let Some(target) = &monitor.mirror_of {
        return format!("{},preferred,auto,{:.2},mirror,{}", monitor.name, monitor.scale, target);
    }
    format!(
        "{},{},{}x{},{:.2}",
        monitor.name,
        mode_string(monitor),
        monitor.x,
        monitor.y,
        monitor.scale
    )
}

fn apply_monitors_live(monitors: &[Monitor]) {
    let cmds: Vec<String> = monitors
        .iter()
        .map(|m| format!("keyword monitor {}", monitor_config(m)))
        .collect();
    if !cmds.is_empty() {
        hyprctl_batch(&cmds);
    }
}

fn active_monitor_count() -> usize {
    get_monitors()
        .iter()
        .filter(|m| !m.disabled && m.width > 0 && m.height > 0)
        .count()
}

fn waybar_running() -> bool {
    Command::new("pgrep")
        .args(["-x", "waybar"])
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn restart_waybar() {
    // Kill existing waybar and restart so it appears on all monitors
    let _ = Command::new("killall").arg("waybar").output();
    thread::sleep(Duration::from_millis(300));
    let dispatched = Command::new("hyprctl")
        .args(["dispatch", "exec", "waybar"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false);

    if !dispatched {
        let _ = Command::new("waybar")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

// Layer-shell clients (waybar, wallpaper) keep stale surface anchors when
// monitors move — bars end up drawn off-screen (2026-08-01 incident).
// Waybar's SIGUSR2 in-process reload re-creates its bars reliably; full
// process restarts proved racy (the first bar created can miss its
// initial .configure and die).
fn reload_waybar_surfaces() {
    let _ = Command::new("pkill")
        .args(["-SIGUSR2", "-x", "waybar"])
        .output();
}

fn validate_visible_session() -> bool {
    if active_monitor_count() == 0 {
        return false;
    }
    if waybar_running() {
        return true;
    }
    restart_waybar();
    thread::sleep(Duration::from_millis(800));
    waybar_running()
}

fn restore_monitor_snapshot(snapshot: &[Monitor]) {
    apply_monitors_live(snapshot);
}

fn reset_to_laptop_only(primary: &Monitor) {
    let reset = format!(
        "{},{},0x0,{:.2}",
        primary.name,
        mode_string(primary),
        primary.scale
    );
    hyprctl(&["keyword", "monitor", &reset]);
    restart_waybar();
}

// ── Persistence ──────────────────────────────────────────────────────
//
// The single source of truth for what gets written is the LIVE hyprland
// state (re-fetched after a successful apply). Every active monitor is
// persisted with its mode PINNED — never "preferred" — because a flaky
// DP reconnect can renegotiate to 1080p and shift/overlap the layout.
//
// Pinning alone is not enough though: if the live state is ITSELF the
// renegotiated 1080p, pinning makes the downgrade permanent. That is exactly
// what happened on 2026-08-07. heal_degraded_modes() below is the guard.

fn persist_from_live(intent: &[Monitor]) {
    let mut mons = get_monitors();
    heal_degraded_modes(&mut mons, intent);
    persist_layout(&mons);
}

fn best_mode(m: &Monitor) -> Option<(u64, u64, f64)> {
    m.available_modes.first().and_then(|s| parse_mode(s))
}

// Is the live mode a strict downgrade from the best mode hyprland reports?
fn is_degraded(m: &Monitor) -> bool {
    match best_mode(m) {
        Some((w, h, rr)) => {
            m.width * m.height < w * h
                || (m.width == w && m.height == h && m.refresh + 0.5 < rr)
        }
        None => false,
    }
}

// hyprland lists availableModes best-first. A monitor coming back BELOW that
// best mode means the link renegotiated behind our back — after a resume from
// suspend hyprland's atomic modeset test for the native mode can fail, and it
// then silently falls back (2560x1440 -> 1920x1080) and never retries.
// Persisting that is what turns a transient glitch into a permanent one: the
// pinned-mode rule below freezes the downgrade into monitors.conf forever.
// So re-apply the best mode before writing — unless the user explicitly asked
// for the lower one, which `intent` (the modes they picked) records.
fn heal_degraded_modes(mons: &mut Vec<Monitor>, intent: &[Monitor]) {
    let mut fixes = Vec::new();
    for m in mons.iter() {
        if m.disabled || m.mirror_of.is_some() || !is_degraded(m) {
            continue;
        }
        let user_asked_for_this = intent
            .iter()
            .find(|i| i.name == m.name)
            .is_some_and(|i| i.width == m.width && i.height == m.height);
        if user_asked_for_this {
            continue;
        }
        let Some((w, h, rr)) = best_mode(m) else { continue };
        fixes.push(format!(
            "keyword monitor {},{}x{}@{:.2},{}x{},{:.2}",
            m.name, w, h, rr, m.x, m.y, m.scale
        ));
    }
    if fixes.is_empty() {
        return;
    }
    let _ = Command::new("hyprctl")
        .args(["--batch", &fixes.join(" ; ")])
        .output();
    thread::sleep(Duration::from_millis(600));
    *mons = get_monitors();
}

fn persist_layout(mons: &[Monitor]) {
    let Some(monitors_path) = home_config_path("monitors.conf") else {
        return;
    };

    let mut lines = vec![
        "# Managed by monitor-chooser (layout editor / preset menu).".to_string(),
        "# Modes are PINNED (not \"preferred\") — a flaky reconnect can".to_string(),
        "# renegotiate to 1080p, which then shifts/overlaps the layout.".to_string(),
        String::new(),
    ];
    // Stable order: left-to-right, disabled monitors last
    let mut sorted: Vec<&Monitor> = mons.iter().collect();
    sorted.sort_by_key(|m| (m.disabled, m.x));
    for m in &sorted {
        lines.push(format!("monitor={}", monitor_config(m)));
    }
    lines.push(String::new());
    let _ = fs::write(monitors_path, lines.join("\n"));

    persist_side_file(mons);
}

// monitor-side keeps the waybar widget's notion of the layout:
//   line 1: current side (external-left/right, mirror, ignore)
//   line 2: external monitor name
//   line 3: last extended side (for mirror-toggle to return to)
fn persist_side_file(mons: &[Monitor]) {
    let Some(side_path) = home_config_path("monitor-side") else {
        return;
    };
    let internal = mons.iter().find(|m| m.name.starts_with("eDP"));
    let external = mons.iter().find(|m| !m.name.starts_with("eDP"));
    let (Some(internal), Some(external)) = (internal, external) else {
        return; // single-monitor machine: leave the file alone
    };

    let side = if external.mirror_of.is_some() || internal.mirror_of.is_some() {
        "mirror"
    } else if external.disabled {
        "ignore"
    } else if external.x < internal.x {
        "external-left"
    } else {
        "external-right"
    };

    let last_extend = if side == "external-left" || side == "external-right" {
        side.to_string()
    } else {
        fs::read_to_string(&side_path)
            .ok()
            .and_then(|contents| contents.lines().nth(2).map(str::to_string))
            .filter(|s| s == "external-left" || s == "external-right")
            .unwrap_or_else(|| "external-right".to_string())
    };

    if let Some(parent) = side_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(
        &side_path,
        format!("{}\n{}\n{}\n", side, external.name, last_extend),
    );
}

// ── Preset choices (hotplug menu) ────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum Choice {
    ExtendRight,
    ExtendLeft,
    Mirror,
    Ignore,
}

const CHOICES: [(Choice, &str, &str); 4] = [
    (
        Choice::ExtendRight,
        "External Right",
        "Place external monitor to the right of laptop",
    ),
    (
        Choice::ExtendLeft,
        "External Left",
        "Place external monitor to the left of laptop",
    ),
    (
        Choice::Mirror,
        "Mirror/Duplicate",
        "Mirror the primary display",
    ),
    (Choice::Ignore, "Ignore (Disable)", "Turn off this monitor"),
];

// Index one past the preset rows: the big Layout Editor button.
const BUTTON_IDX: usize = CHOICES.len();

fn centered_y_for_external(primary: &Monitor, external: &Monitor) -> i64 {
    let reference_h = monitor_logical_height(external);
    let moving_h = monitor_logical_height(primary);
    if reference_h > moving_h {
        (reference_h - moving_h) / 2
    } else {
        0
    }
}

fn move_orphan_windows_to_primary(ext_monitor: &str) {
    // Move all windows on the external monitor back to workspace 1 before
    // it goes away (mirror/disable). The workspace-pairs daemon re-homes
    // workspaces itself once the monitor set changes.
    let Ok(output) = Command::new("hyprctl").args(["clients", "-j"]).output() else {
        return;
    };
    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).unwrap_or(serde_json::Value::Array(vec![]));

    if let Some(clients) = json.as_array() {
        for client in clients {
            let mon = client["monitor"].as_str().unwrap_or("");
            if mon == ext_monitor {
                if let Some(addr) = client["address"].as_str() {
                    hyprctl(&[
                        "dispatch",
                        "movetoworkspacesilent",
                        &format!("1,address:{}", addr),
                    ]);
                }
            }
        }
    }
}

fn apply_choice(choice: Choice, new_mon: &str, primary: &Monitor) -> Result<(), String> {
    let before = get_monitors();
    let monitors = get_monitors();
    let new_monitor = monitors
        .iter()
        .find(|m| m.name == new_mon)
        .cloned()
        .unwrap_or_else(|| Monitor {
            name: new_mon.to_string(),
            width: 2560,
            height: 1440,
            refresh: 60.0,
            x: 0,
            y: 0,
            scale: 1.0,
            focused: false,
            disabled: false,
            mirror_of: None,
            available_modes: vec![],
        });

    // Pin the external's current mode; "preferred" only if hyprland
    // reports no usable mode yet.
    let ext_mode = if new_monitor.width > 0 {
        mode_string(&new_monitor)
    } else {
        "preferred".to_string()
    };

    let mut commands = Vec::new();

    match choice {
        Choice::ExtendRight => {
            let primary_y = centered_y_for_external(primary, &new_monitor);
            let ext_x = monitor_logical_width(primary);
            commands.push(format!(
                "{},{},0x{},{:.2}",
                primary.name,
                mode_string(primary),
                primary_y,
                primary.scale
            ));
            commands.push(format!("{},{},{}x0,1", new_mon, ext_mode, ext_x));
        }
        Choice::ExtendLeft => {
            let primary_x = monitor_logical_width(&new_monitor);
            let primary_y = centered_y_for_external(primary, &new_monitor);
            commands.push(format!("{},{},0x0,1", new_mon, ext_mode));
            commands.push(format!(
                "{},{},{}x{},{:.2}",
                primary.name,
                mode_string(primary),
                primary_x,
                primary_y,
                primary.scale
            ));
        }
        Choice::Mirror => {
            move_orphan_windows_to_primary(new_mon);
            commands.push(format!(
                "{},preferred,auto,1,mirror,{}",
                new_mon, primary.name
            ));
        }
        Choice::Ignore => {
            move_orphan_windows_to_primary(new_mon);
            commands.push(format!("{},disabled", new_mon));
        }
    }

    // For mirror/ignore: reset primary to 0x0 since it's effectively alone
    if choice == Choice::Mirror || choice == Choice::Ignore {
        commands.push(format!(
            "{},{},0x0,{:.2}",
            primary.name,
            mode_string(primary),
            primary.scale
        ));
    }

    hyprctl_batch(
        &commands
            .iter()
            .map(|cmd| format!("keyword monitor {}", cmd))
            .collect::<Vec<_>>(),
    );

    // Workspace→monitor pairing rules are owned by workspace-pairs-daemon;
    // it reacts to the monitor change on its own — nothing to do here.

    // Re-anchor waybar on the changed layout: in-process reload if it's
    // alive (reliable), full restart only if it's gone.
    if choice != Choice::Ignore {
        if waybar_running() {
            reload_waybar_surfaces();
        } else {
            restart_waybar();
        }
    }

    thread::sleep(Duration::from_millis(1200));
    if !validate_visible_session() {
        restore_monitor_snapshot(&before);
        restart_waybar();
        thread::sleep(Duration::from_millis(1200));

        if !validate_visible_session() {
            reset_to_laptop_only(primary);
        }

        return Err("Layout failed safety validation; previous layout was restored".to_string());
    }

    // No explicit user mode pick on the hotplug path — always heal to best.
    persist_from_live(&[]);
    Ok(())
}

// ── Layout editor ────────────────────────────────────────────────────

// Maps layout coordinates (logical px) to terminal cells. Terminal cells
// are ~2x taller than wide, hence the 0.5 factor on the y axis.
#[derive(Clone, Copy)]
struct View {
    min_x: f64,
    min_y: f64,
    s: f64,
    area: Rect,
}

impl View {
    fn cell_rect(&self, m: &Monitor) -> Rect {
        let lw = monitor_logical_width(m) as f64;
        let lh = monitor_logical_height(m) as f64;
        // Round both EDGES (not position + size independently): monitors
        // that are flush in layout coords must share an edge column, or
        // snapped-together boxes render with a phantom 1-cell gap.
        let x0 = ((m.x as f64 - self.min_x) * self.s).round() as i64;
        let x1 = ((m.x as f64 + lw - self.min_x) * self.s).round() as i64;
        let y0 = ((m.y as f64 - self.min_y) * self.s * 0.5).round() as i64;
        let y1 = ((m.y as f64 + lh - self.min_y) * self.s * 0.5).round() as i64;
        let x = self.area.x as i64 + x0;
        let y = self.area.y as i64 + y0;
        let w = ((x1 - x0).max(0) as u16).max(14);
        let h = ((y1 - y0).max(0) as u16).max(4);
        let r = Rect {
            x: x.clamp(0, u16::MAX as i64) as u16,
            y: y.clamp(0, u16::MAX as i64) as u16,
            width: w,
            height: h,
        };
        r.intersection(self.area)
    }

    fn to_layout(&self, col: u16, row: u16) -> (i64, i64) {
        let lx = self.min_x + (col.saturating_sub(self.area.x)) as f64 / self.s;
        let ly = self.min_y + (row.saturating_sub(self.area.y)) as f64 / (self.s * 0.5);
        (lx as i64, ly as i64)
    }
}

struct Picker {
    modes: Vec<String>,
    selected: usize,
}

struct Drag {
    grab_dx: i64,
    grab_dy: i64,
}

// How two monitors' nearest edges relate, in logical px.
enum EdgeRelation {
    Overlap(i64),
    Flush,
    Gap(i64),
}

struct LayoutApp {
    mons: Vec<Monitor>,     // working copy — a PREVIEW; applied only on save
    snapshot: Vec<Monitor>, // last known-good live state (restored if save fails)
    selected: usize,
    picker: Option<Picker>,
    drag: Option<Drag>,
    dirty: bool,
    status: String,
    view: Option<View>,
    // Frozen viewport in layout coords. Bounds only ever grow while
    // editing, so moving one monitor never rescales/shifts the others.
    bounds: (f64, f64, f64, f64), // (min_x, min_y, max_x, max_y)
    quit: bool,
}

impl LayoutApp {
    fn new() -> Self {
        let mons = get_monitors();
        let selected = mons
            .iter()
            .position(|m| !m.disabled)
            .unwrap_or(0);
        let mut app = LayoutApp {
            snapshot: mons.clone(),
            mons,
            selected,
            picker: None,
            drag: None,
            dirty: false,
            status: "Preview only — nothing is applied until Enter".into(),
            view: None,
            bounds: (0.0, 0.0, 1.0, 1.0),
            quit: false,
        };
        app.fit_bounds();
        app
    }

    // Recompute the viewport to fit the current layout with generous
    // padding. Called on entry, after snap-all, and after save — NOT per
    // frame, so the view stays stable while dragging.
    fn fit_bounds(&mut self) {
        let placed: Vec<&Monitor> = self
            .mons
            .iter()
            .filter(|m| !m.disabled && m.mirror_of.is_none())
            .collect();
        if placed.is_empty() {
            return;
        }
        let min_x = placed.iter().map(|m| m.x).min().unwrap() as f64;
        let min_y = placed.iter().map(|m| m.y).min().unwrap() as f64;
        let max_x = placed
            .iter()
            .map(|m| m.x + monitor_logical_width(m))
            .max()
            .unwrap() as f64;
        let max_y = placed
            .iter()
            .map(|m| m.y + monitor_logical_height(m))
            .max()
            .unwrap() as f64;
        let pad_x = ((max_x - min_x) * 0.3).max(500.0);
        let pad_y = ((max_y - min_y) * 0.3).max(500.0);
        self.bounds = (min_x - pad_x, min_y - pad_y, max_x + pad_x, max_y + pad_y);
    }

    // Grow (never shrink) the viewport if a monitor was dragged outside it.
    fn grow_bounds_if_needed(&mut self) {
        const MARGIN: f64 = 200.0;
        for m in &self.mons {
            if m.disabled || m.mirror_of.is_some() {
                continue;
            }
            let (x0, y0) = (m.x as f64, m.y as f64);
            let x1 = (m.x + monitor_logical_width(m)) as f64;
            let y1 = (m.y + monitor_logical_height(m)) as f64;
            self.bounds.0 = self.bounds.0.min(x0 - MARGIN);
            self.bounds.1 = self.bounds.1.min(y0 - MARGIN);
            self.bounds.2 = self.bounds.2.max(x1 + MARGIN);
            self.bounds.3 = self.bounds.3.max(y1 + MARGIN);
        }
    }

    fn selected_mon(&self) -> Option<&Monitor> {
        self.mons.get(self.selected)
    }

    fn cycle_selected(&mut self, dir: i64) {
        if self.mons.is_empty() {
            return;
        }
        let n = self.mons.len() as i64;
        self.selected = ((self.selected as i64 + dir).rem_euclid(n)) as usize;
    }

    fn move_selected(&mut self, dx: i64, dy: i64) {
        if let Some(m) = self.mons.get_mut(self.selected) {
            if m.disabled {
                return;
            }
            m.x += dx;
            m.y += dy;
            self.dirty = true;
            self.grow_bounds_if_needed();
        }
    }

    // Snap ALL monitors edge-to-edge: anchor the leftmost, then attach
    // each remaining monitor to the placed set at the adjacent position
    // (right/left/above/below, with edge or center alignment) closest to
    // where the user left it. Removes gaps and overlaps in one press.
    fn snap_all(&mut self) {
        let mut idxs: Vec<usize> = self
            .mons
            .iter()
            .enumerate()
            .filter(|(_, m)| !m.disabled && m.mirror_of.is_none())
            .map(|(i, _)| i)
            .collect();
        if idxs.len() < 2 {
            return;
        }
        idxs.sort_by_key(|&i| (self.mons[i].x, self.mons[i].y));

        // (x, y, w, h) of monitors already placed
        let anchor = &self.mons[idxs[0]];
        let mut placed: Vec<(i64, i64, i64, i64)> = vec![(
            anchor.x,
            anchor.y,
            monitor_logical_width(anchor),
            monitor_logical_height(anchor),
        )];

        for &i in &idxs[1..] {
            let (cx, cy) = (self.mons[i].x, self.mons[i].y);
            let mw = monitor_logical_width(&self.mons[i]);
            let mh = monitor_logical_height(&self.mons[i]);

            let mut best: Option<(i64, (i64, i64))> = None; // (dist², pos)
            for &(px, py, pw, ph) in &placed {
                let mut cands = Vec::new();
                for y in [py, py + (ph - mh) / 2, py + ph - mh] {
                    cands.push((px + pw, y)); // right of
                    cands.push((px - mw, y)); // left of
                }
                for x in [px, px + (pw - mw) / 2, px + pw - mw] {
                    cands.push((x, py + ph)); // below
                    cands.push((x, py - mh)); // above
                }
                for (x, y) in cands {
                    let d = (x - cx) * (x - cx) + (y - cy) * (y - cy);
                    if best.map_or(true, |(bd, _)| d < bd) {
                        best = Some((d, (x, y)));
                    }
                }
            }
            if let Some((_, (x, y))) = best {
                self.mons[i].x = x;
                self.mons[i].y = y;
            }
            let m = &self.mons[i];
            placed.push((m.x, m.y, mw, mh));
        }

        self.dirty = true;
        self.fit_bounds();
        self.status = "Edges snapped — Enter to apply".into();
    }

    fn toggle_disabled(&mut self) {
        let others_active = self
            .mons
            .iter()
            .enumerate()
            .any(|(i, m)| i != self.selected && !m.disabled);
        if let Some(m) = self.mons.get_mut(self.selected) {
            if !m.disabled && !others_active {
                self.status = "Refusing to disable the last active monitor".into();
                return;
            }
            m.disabled = !m.disabled;
            if !m.disabled && m.width == 0 {
                // Re-enable with something sane; the picker can refine it.
                if let Some((w, h, rr)) = m.available_modes.first().and_then(|s| parse_mode(s)) {
                    m.width = w;
                    m.height = h;
                    m.refresh = rr;
                } else {
                    m.width = 1920;
                    m.height = 1080;
                    m.refresh = 60.0;
                }
            }
            self.dirty = true;
        }
        self.fit_bounds();
    }

    fn open_picker(&mut self) {
        let Some(m) = self.selected_mon() else { return };
        if m.available_modes.is_empty() {
            self.status = format!("{}: no modes reported by hyprland", m.name);
            return;
        }
        let current = mode_string(m);
        let selected = m
            .available_modes
            .iter()
            .position(|s| s.trim_end_matches("Hz") == current)
            .unwrap_or(0);
        self.picker = Some(Picker {
            modes: m.available_modes.clone(),
            selected,
        });
    }

    fn pick_mode(&mut self) {
        let Some(picker) = self.picker.take() else { return };
        let Some(mode) = picker.modes.get(picker.selected) else { return };
        let Some((w, h, rr)) = parse_mode(mode) else {
            self.status = format!("Could not parse mode: {}", mode);
            return;
        };
        if let Some(m) = self.mons.get_mut(self.selected) {
            m.width = w;
            m.height = h;
            m.refresh = rr;
        }
        self.dirty = true;
        self.status = format!("Mode set to {}x{}@{:.2} — s to snap, Enter to apply", w, h, rr);
    }

    // Origin the layout gets normalized to on save (top-left active
    // monitor lands at 0x0). Displayed coordinates subtract this so the
    // numbers always match what will actually be applied.
    fn norm_origin(&self) -> (i64, i64) {
        let active = || {
            self.mons
                .iter()
                .filter(|m| !m.disabled && m.mirror_of.is_none())
        };
        let min_x = active().map(|m| m.x).min().unwrap_or(0);
        let min_y = active().map(|m| m.y).min().unwrap_or(0);
        (min_x, min_y)
    }

    // Pairwise edge relationships between active monitors. The preview's
    // cell resolution (~60-90 logical px per cell) can't show whether
    // edges are flush, so the status line carries the exact numbers.
    fn edge_relations(&self) -> Vec<(String, String, EdgeRelation)> {
        let active: Vec<&Monitor> = self
            .mons
            .iter()
            .filter(|m| !m.disabled && m.mirror_of.is_none())
            .collect();
        let mut rels = Vec::new();
        for (i, a) in active.iter().enumerate() {
            for b in active.iter().skip(i + 1) {
                let (aw, ah) = (monitor_logical_width(a), monitor_logical_height(a));
                let (bw, bh) = (monitor_logical_width(b), monitor_logical_height(b));
                // Signed separation per axis: >0 gap, 0 touching, <0 overlap
                let dx = (b.x - (a.x + aw)).max(a.x - (b.x + bw));
                let dy = (b.y - (a.y + ah)).max(a.y - (b.y + bh));
                let rel = if dx < 0 && dy < 0 {
                    EdgeRelation::Overlap((-dx).min(-dy))
                } else if dx.max(dy) == 0 {
                    EdgeRelation::Flush
                } else {
                    EdgeRelation::Gap(dx.max(dy))
                };
                rels.push((a.name.clone(), b.name.clone(), rel));
            }
        }
        rels
    }

    fn save(&mut self) {
        // Normalize so the top-left of the layout is at 0x0
        let (min_x, min_y) = self.norm_origin();
        for m in &mut self.mons {
            if !m.disabled && m.mirror_of.is_none() {
                m.x -= min_x;
                m.y -= min_y;
            }
        }

        apply_monitors_live(&self.mons);
        thread::sleep(Duration::from_millis(500));

        if !validate_visible_session() {
            restore_monitor_snapshot(&self.snapshot);
            reload_waybar_surfaces();
            self.mons = self.snapshot.clone();
            self.dirty = false;
            self.fit_bounds();
            self.status = "Apply FAILED validation — previous layout restored".into();
            return;
        }

        // Monitors moved: re-anchor waybar's layer surfaces
        reload_waybar_surfaces();

        // Persist from live state so we record what hyprland actually set —
        // but pass the edited monitors as intent, so a mode the user picked in
        // the resolution picker is honoured while a silent downgrade is healed.
        persist_from_live(&self.mons);
        self.mons = get_monitors();
        self.selected = self.selected.min(self.mons.len().saturating_sub(1));
        self.snapshot = self.mons.clone();
        self.dirty = false;
        self.fit_bounds();
        self.status = "Applied & saved — pinned modes written to monitors.conf".into();
    }

    // Edits are preview-only, so quitting never has to touch hyprland.
    fn quit_editor(&mut self) {
        self.quit = true;
    }
}

fn ui_layout(frame: &mut Frame, app: &mut LayoutApp) {
    let area = frame.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1), // header
            Constraint::Min(10),   // canvas
            Constraint::Length(3), // details / status
            Constraint::Length(2), // key help
        ])
        .split(area);

    let header = Paragraph::new(Line::from(vec![
        Span::styled("Monitor Layout Editor", Style::default().fg(Color::Cyan).bold()),
        Span::styled(
            if app.dirty {
                "  [preview — Enter applies]"
            } else {
                ""
            },
            Style::default().fg(Color::Yellow),
        ),
    ]))
    .alignment(Alignment::Center);
    frame.render_widget(header, chunks[0]);

    // Canvas
    let canvas_block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray))
        .title(" Layout — drag with mouse or move with arrows ");
    let inner = canvas_block.inner(chunks[1]);
    frame.render_widget(canvas_block, chunks[1]);

    let placed: Vec<&Monitor> = app
        .mons
        .iter()
        .filter(|m| !m.disabled && m.mirror_of.is_none())
        .collect();

    if !placed.is_empty() && inner.width > 4 && inner.height > 4 {
        // Frozen viewport: bounds live in app state and only grow while
        // editing, so moving one monitor never rescales the others.
        let (bx0, by0, bx1, by1) = app.bounds;
        let span_x = (bx1 - bx0).max(1.0);
        let span_y = (by1 - by0).max(1.0);
        let s = f64::min(
            (inner.width as f64 - 2.0) / span_x,
            (inner.height as f64 - 1.0) * 2.0 / span_y,
        );
        let view = View {
            min_x: bx0,
            min_y: by0,
            s,
            area: inner,
        };
        app.view = Some(view);

        let (ox, oy) = app.norm_origin();
        for (i, m) in app.mons.iter().enumerate() {
            if m.disabled || m.mirror_of.is_some() {
                continue;
            }
            let r = view.cell_rect(m);
            if r.width < 3 || r.height < 2 {
                continue;
            }
            let sel = i == app.selected;
            let border_style = if sel {
                Style::default().fg(Color::Cyan).bold()
            } else {
                Style::default().fg(Color::DarkGray)
            };
            let title = format!(
                " {}{} ",
                m.name,
                if m.focused { " ●" } else { "" }
            );
            let body = vec![
                Line::from(Span::styled(
                    mode_string(m),
                    Style::default().fg(if sel { Color::White } else { Color::Gray }),
                )),
                Line::from(Span::styled(
                    format!("+{}+{}", m.x - ox, m.y - oy),
                    Style::default().fg(Color::DarkGray),
                )),
            ];
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(border_style)
                .title(Span::styled(title, border_style));
            frame.render_widget(
                Paragraph::new(body).alignment(Alignment::Center).block(block),
                r,
            );
        }
    } else {
        app.view = None;
    }

    // Details / status
    let mut detail_lines = Vec::new();
    if let Some(m) = app.selected_mon() {
        let state = if m.disabled {
            " (disabled)"
        } else if m.mirror_of.is_some() {
            " (mirroring)"
        } else {
            ""
        };
        let (ox, oy) = app.norm_origin();
        detail_lines.push(Line::from(vec![
            Span::styled("Selected: ", Style::default().fg(Color::DarkGray)),
            Span::styled(m.name.clone(), Style::default().fg(Color::Cyan).bold()),
            Span::styled(
                format!(
                    "  {} at +{}+{} scale {:.2}{}",
                    mode_string(m),
                    m.x - ox,
                    m.y - oy,
                    m.scale,
                    state
                ),
                Style::default().fg(Color::Gray),
            ),
        ]));
    }
    let disabled: Vec<String> = app
        .mons
        .iter()
        .filter(|m| m.disabled)
        .map(|m| m.name.clone())
        .collect();
    let mut status_spans = Vec::new();
    for (a, b, rel) in app.edge_relations() {
        status_spans.push(match rel {
            EdgeRelation::Overlap(px) => Span::styled(
                format!("⚠ {} and {} overlap {}px — press s to snap edges  ", a, b, px),
                Style::default().fg(Color::Red).bold(),
            ),
            EdgeRelation::Flush => Span::styled(
                format!("✓ {} flush with {}  ", a, b),
                Style::default().fg(Color::Green).bold(),
            ),
            EdgeRelation::Gap(px) => Span::styled(
                format!("{} ↔ {}: gap {}px — s to snap  ", a, b, px),
                Style::default().fg(Color::Yellow),
            ),
        });
    }
    if !disabled.is_empty() {
        status_spans.push(Span::styled(
            format!("(disabled: {})  ", disabled.join(", ")),
            Style::default().fg(Color::DarkGray),
        ));
    }
    status_spans.push(Span::styled(
        app.status.clone(),
        Style::default().fg(Color::Green),
    ));
    detail_lines.push(Line::from(status_spans));

    frame.render_widget(
        Paragraph::new(detail_lines).block(
            Block::default()
                .borders(Borders::TOP)
                .border_style(Style::default().fg(Color::DarkGray)),
        ),
        chunks[2],
    );

    // Key help
    let help = Paragraph::new(vec![
        Line::from(vec![
            Span::styled(" [Tab] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Select", Style::default().fg(Color::DarkGray)),
            Span::styled("  [Arrows] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Move (Shift=fine)", Style::default().fg(Color::DarkGray)),
            Span::styled("  [s] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Snap edges", Style::default().fg(Color::DarkGray)),
            Span::styled("  [r] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Resolution", Style::default().fg(Color::DarkGray)),
            Span::styled("  [d] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Enable/disable", Style::default().fg(Color::DarkGray)),
        ]),
        Line::from(vec![
            Span::styled(" [Enter/w] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Apply & save (pinned)", Style::default().fg(Color::DarkGray)),
            Span::styled("  [Esc/q] ", Style::default().fg(Color::Yellow).bold()),
            Span::styled("Quit without applying", Style::default().fg(Color::DarkGray)),
        ]),
    ]);
    frame.render_widget(help, chunks[3]);

    // Resolution picker overlay
    if let Some(picker) = &app.picker {
        let name = app
            .selected_mon()
            .map(|m| m.name.clone())
            .unwrap_or_default();
        let w = 36u16.min(area.width.saturating_sub(4));
        let h = ((picker.modes.len() as u16) + 2).min(area.height.saturating_sub(4)).max(3);
        let popup = Rect {
            x: area.x + (area.width.saturating_sub(w)) / 2,
            y: area.y + (area.height.saturating_sub(h)) / 2,
            width: w,
            height: h,
        };
        frame.render_widget(Clear, popup);

        let current = app.selected_mon().map(mode_string).unwrap_or_default();
        let items: Vec<ListItem> = picker
            .modes
            .iter()
            .enumerate()
            .map(|(i, mode)| {
                let is_current = mode.trim_end_matches("Hz") == current;
                let marker = if is_current { "● " } else { "  " };
                let style = if i == picker.selected {
                    Style::default().fg(Color::Black).bg(Color::Cyan).bold()
                } else if is_current {
                    Style::default().fg(Color::Green)
                } else {
                    Style::default().fg(Color::White)
                };
                ListItem::new(Span::styled(format!("{}{}", marker, mode), style))
            })
            .collect();

        // Scroll the list so the selection stays visible
        let visible = h.saturating_sub(2) as usize;
        let offset = picker.selected.saturating_sub(visible.saturating_sub(1));
        let list = List::new(items.into_iter().skip(offset).collect::<Vec<_>>()).block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(Color::Cyan))
                .title(format!(" Resolution — {} ", name)),
        );
        frame.render_widget(list, popup);
    }
}

fn run_layout_editor(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut app = LayoutApp::new();

    while !app.quit {
        terminal.draw(|f| ui_layout(f, &mut app))?;

        match event::read()? {
            Event::Key(key) if key.kind == KeyEventKind::Press => {
                if let Some(picker) = &mut app.picker {
                    match key.code {
                        KeyCode::Up | KeyCode::Char('k') => {
                            picker.selected = picker.selected.saturating_sub(1);
                        }
                        KeyCode::Down | KeyCode::Char('j') => {
                            if picker.selected + 1 < picker.modes.len() {
                                picker.selected += 1;
                            }
                        }
                        KeyCode::Enter => app.pick_mode(),
                        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('r') => {
                            app.picker = None;
                        }
                        _ => {}
                    }
                    continue;
                }

                let fine = key.modifiers.contains(KeyModifiers::SHIFT);
                let step = if fine { 10 } else { 80 };
                match key.code {
                    KeyCode::Esc | KeyCode::Char('q') => app.quit_editor(),
                    KeyCode::Tab | KeyCode::Char('n') => app.cycle_selected(1),
                    KeyCode::BackTab | KeyCode::Char('p') => app.cycle_selected(-1),
                    KeyCode::Left | KeyCode::Char('h') => app.move_selected(-step, 0),
                    KeyCode::Right | KeyCode::Char('l') => app.move_selected(step, 0),
                    KeyCode::Up | KeyCode::Char('k') => app.move_selected(0, -step),
                    KeyCode::Down | KeyCode::Char('j') => app.move_selected(0, step),
                    KeyCode::Char('s') => app.snap_all(),
                    KeyCode::Char('r') => app.open_picker(),
                    KeyCode::Char('d') => app.toggle_disabled(),
                    KeyCode::Enter | KeyCode::Char('w') => app.save(),
                    _ => {}
                }
            }
            Event::Mouse(me) => {
                let Some(view) = app.view else { continue };
                match me.kind {
                    MouseEventKind::Down(MouseButton::Left) => {
                        // Topmost hit wins; iterate in reverse draw order
                        let hit = app
                            .mons
                            .iter()
                            .enumerate()
                            .filter(|(_, m)| !m.disabled && m.mirror_of.is_none())
                            .rev()
                            .find(|(_, m)| {
                                let r = view.cell_rect(m);
                                me.column >= r.x
                                    && me.column < r.x + r.width
                                    && me.row >= r.y
                                    && me.row < r.y + r.height
                            })
                            .map(|(i, _)| i);
                        if let Some(i) = hit {
                            app.selected = i;
                            let (lx, ly) = view.to_layout(me.column, me.row);
                            let m = &app.mons[i];
                            app.drag = Some(Drag {
                                grab_dx: lx - m.x,
                                grab_dy: ly - m.y,
                            });
                        }
                    }
                    MouseEventKind::Drag(MouseButton::Left) => {
                        if let Some(drag) = &app.drag {
                            let (lx, ly) = view.to_layout(me.column, me.row);
                            let (nx, ny) = (lx - drag.grab_dx, ly - drag.grab_dy);
                            if let Some(m) = app.mons.get_mut(app.selected) {
                                // Round to 10px so coordinates stay tidy
                                m.x = (nx as f64 / 10.0).round() as i64 * 10;
                                m.y = (ny as f64 / 10.0).round() as i64 * 10;
                            }
                            app.dirty = true;
                            app.grow_bounds_if_needed();
                        }
                    }
                    MouseEventKind::Up(MouseButton::Left) => {
                        if app.drag.take().is_some() {
                            app.status =
                                "Moved — s to snap edges, Enter to apply".into();
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    Ok(())
}

// ── Preset menu state / UI ───────────────────────────────────────────

struct App {
    selected: usize, // 0..CHOICES.len() = preset rows, BUTTON_IDX = editor button
    new_monitor: String,
    primary: Monitor,
    // Hit-rects captured at draw time so the event loop can map mouse
    // coordinates back to rows/button (same pattern as LayoutApp.view).
    list_inner: Option<Rect>,
    button: Option<Rect>,
}

impl App {
    // What a mouse position lands on: a preset row or the editor button.
    fn hit(&self, col: u16, row: u16) -> Option<usize> {
        let inside = |r: Rect| {
            col >= r.x && col < r.x + r.width && row >= r.y && row < r.y + r.height
        };
        if let Some(list) = self.list_inner {
            if inside(list) {
                let i = (row - list.y) as usize;
                if i < CHOICES.len() {
                    return Some(i);
                }
            }
        }
        if self.button.is_some_and(inside) {
            return Some(BUTTON_IDX);
        }
        None
    }
}

fn ui(frame: &mut Frame, app: &mut App) {
    let area = frame.area();

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(2)
        .constraints([
            Constraint::Length(3), // Title
            Constraint::Length(2), // Monitor info
            Constraint::Min(6),    // Menu
            Constraint::Length(3), // Layout Editor button
            Constraint::Length(1), // Footer
        ])
        .split(area);

    // Title
    let title = Paragraph::new(Line::from(vec![Span::styled(
        "Monitor Chooser",
        Style::default().fg(Color::Cyan).bold(),
    )]))
    .alignment(Alignment::Center)
    .block(
        Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Double)
            .border_style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(title, chunks[0]);

    // Monitor info
    let info = Paragraph::new(Line::from(vec![
        Span::styled("New monitor: ", Style::default().fg(Color::DarkGray)),
        Span::styled(&app.new_monitor, Style::default().fg(Color::Yellow).bold()),
        Span::styled("  Primary: ", Style::default().fg(Color::DarkGray)),
        Span::styled(
            format!(
                "{} ({}x{})",
                app.primary.name, app.primary.width, app.primary.height
            ),
            Style::default().fg(Color::Green),
        ),
    ]));
    frame.render_widget(info, chunks[1]);

    // Menu
    let items: Vec<ListItem> = CHOICES
        .iter()
        .enumerate()
        .map(|(i, (_, label, desc))| {
            let style = if i == app.selected {
                Style::default().fg(Color::Black).bg(Color::Cyan).bold()
            } else {
                Style::default().fg(Color::White)
            };
            let prefix = if i == app.selected { " > " } else { "   " };
            ListItem::new(Line::from(vec![
                Span::styled(format!("{}{}", prefix, label), style),
                Span::styled(format!("  {}", desc), Style::default().fg(Color::DarkGray)),
            ]))
        })
        .collect();

    let menu_block = Block::default()
        .title(Span::styled(
            " Choose layout ",
            Style::default().fg(Color::White).bold(),
        ))
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray));
    app.list_inner = Some(menu_block.inner(chunks[2]));
    let menu = List::new(items).block(menu_block);
    frame.render_widget(menu, chunks[2]);

    // Big Layout Editor button — clickable, also reachable with Down/l
    let btn_selected = app.selected == BUTTON_IDX;
    let (btn_border, btn_text) = if btn_selected {
        (
            Style::default().fg(Color::Cyan).bold(),
            Style::default().fg(Color::Black).bg(Color::Cyan).bold(),
        )
    } else {
        (
            Style::default().fg(Color::DarkGray),
            Style::default().fg(Color::Cyan).bold(),
        )
    };
    app.button = Some(chunks[3]);
    let button = Paragraph::new(Line::from(Span::styled(
        " Layout Editor — drag monitors, resolutions, fine-tune ",
        btn_text,
    )))
    .alignment(Alignment::Center)
    .block(
        Block::default()
            .borders(Borders::ALL)
            .border_style(btn_border),
    );
    frame.render_widget(button, chunks[3]);

    // Footer
    let footer = Paragraph::new(Line::from(vec![
        Span::styled(" [Up/Down/Mouse] ", Style::default().fg(Color::Yellow).bold()),
        Span::styled("Navigate", Style::default().fg(Color::DarkGray)),
        Span::styled("  [Enter/Click] ", Style::default().fg(Color::Yellow).bold()),
        Span::styled("Apply", Style::default().fg(Color::DarkGray)),
        Span::styled("  [l] ", Style::default().fg(Color::Yellow).bold()),
        Span::styled("Layout editor", Style::default().fg(Color::DarkGray)),
        Span::styled("  [q/Esc] ", Style::default().fg(Color::Yellow).bold()),
        Span::styled("Cancel", Style::default().fg(Color::DarkGray)),
    ]));
    frame.render_widget(footer, chunks[4]);
}

// ── Main ─────────────────────────────────────────────────────────────

fn setup_terminal() -> Result<Terminal<CrosstermBackend<io::Stdout>>, Box<dyn std::error::Error>> {
    enable_raw_mode()?;
    io::stdout().execute(EnterAlternateScreen)?;
    io::stdout().execute(EnableMouseCapture)?;
    Ok(Terminal::new(CrosstermBackend::new(io::stdout()))?)
}

fn teardown_terminal() {
    let _ = disable_raw_mode();
    let _ = io::stdout().execute(DisableMouseCapture);
    let _ = io::stdout().execute(LeaveAlternateScreen);
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    let arg = args.get(1).map(String::as_str);

    if arg == Some("--help") || arg == Some("-h") {
        eprintln!("Usage: monitor-chooser [<new-monitor-name>|--layout]");
        eprintln!();
        eprintln!("  <new-monitor-name>  Preset menu for a newly connected monitor");
        eprintln!("                      (typically launched by monitor-chooser-trigger.sh)");
        eprintln!("  --layout / no args  Visual layout editor: drag monitors with the");
        eprintln!("                      mouse or arrows, pick pinned resolutions, save");
        std::process::exit(0);
    }

    // Layout editor mode
    if arg.is_none() || arg == Some("--layout") {
        let mut terminal = setup_terminal()?;
        let result = run_layout_editor(&mut terminal);
        teardown_terminal();
        return result;
    }

    // Preset menu mode (hotplug flow)
    let new_monitor = args[1].clone();

    let monitors = get_monitors();
    let primary = find_primary(&monitors).cloned().unwrap_or_else(|| Monitor {
        name: "eDP-1".to_string(),
        width: 1920,
        height: 1080,
        refresh: 60.0,
        x: 0,
        y: 0,
        scale: 1.0,
        focused: true,
        disabled: false,
        mirror_of: None,
        available_modes: vec![],
    });

    let mut app = App {
        selected: 0,
        new_monitor: new_monitor.clone(),
        primary,
        list_inner: None,
        button: None,
    };

    let mut terminal = setup_terminal()?;

    enum Action {
        None,
        Activate(usize),
        Quit,
    }

    loop {
        terminal.draw(|f| ui(f, &mut app))?;

        let action = match event::read()? {
            Event::Key(key) if key.kind == KeyEventKind::Press => match key.code {
                KeyCode::Char('q') | KeyCode::Char('Q') | KeyCode::Esc => Action::Quit,
                KeyCode::Up | KeyCode::Char('k') => {
                    app.selected = app.selected.saturating_sub(1);
                    Action::None
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    if app.selected < BUTTON_IDX {
                        app.selected += 1;
                    }
                    Action::None
                }
                KeyCode::Char('l') => Action::Activate(BUTTON_IDX),
                KeyCode::Enter => Action::Activate(app.selected),
                _ => Action::None,
            },
            Event::Mouse(me) => match me.kind {
                MouseEventKind::Moved => {
                    if let Some(i) = app.hit(me.column, me.row) {
                        app.selected = i;
                    }
                    Action::None
                }
                MouseEventKind::Down(MouseButton::Left) => match app.hit(me.column, me.row) {
                    Some(i) => {
                        app.selected = i;
                        Action::Activate(i)
                    }
                    None => Action::None,
                },
                MouseEventKind::ScrollUp => {
                    app.selected = app.selected.saturating_sub(1);
                    Action::None
                }
                MouseEventKind::ScrollDown => {
                    if app.selected < BUTTON_IDX {
                        app.selected += 1;
                    }
                    Action::None
                }
                _ => Action::None,
            },
            _ => Action::None,
        };

        match action {
            Action::Quit => break,
            Action::None => {}
            Action::Activate(BUTTON_IDX) => {
                // Esc/q in the editor returns to this menu, not out of
                // the app — only Esc here quits.
                if let Err(err) = run_layout_editor(&mut terminal) {
                    teardown_terminal();
                    return Err(err);
                }
            }
            Action::Activate(i) => {
                let (choice, label, _) = CHOICES[i];

                // Restore terminal before running hyprctl
                teardown_terminal();

                match apply_choice(choice, &new_monitor, &app.primary) {
                    Ok(()) => println!("Applied: {} for {}", label, new_monitor),
                    Err(err) => {
                        eprintln!("{}", err);
                        std::process::exit(2);
                    }
                }
                return Ok(());
            }
        }
    }

    teardown_terminal();
    Ok(())
}
