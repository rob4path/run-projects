#!/usr/bin/env bash
#
# dev.sh — run a group of projects' dev servers, in VSCode (default), Warp, or headless.
#
# Each group has its own config <name>.config.json and is run as `<name>` (e.g. `myapp up`);
# `dev` is the umbrella tool. A group's "mode" picks how `up` runs servers:
#   vscode (default) — each project in its own VSCode window, server in its terminal
#                      (projects with "workspace": true instead share one multi-root window)
#   warp             — Warp opens a window with native split panes (all logs together)
#   run              — headless: servers run in the background, output to .dev-logs (no editor)
#
#   dev up [names...]      run the group's servers using its configured mode
#                          no names -> only projects flagged "isMain": true;  use "all" for every one
#   dev vscode [names...]  force VSCode mode  (ignore the config's mode)
#   dev warp  [names...]   force Warp mode
#   dev run   [names...]   force headless mode — background servers, logs in .dev-logs, no editor
#   dev down [names...]    stop those servers ("all" = the whole group, windows stay open)
#                          no names -> stop the group's servers AND close only its windows
#                          (as `dev`: close every configured group's windows)
#   dev down --quit-all    quit ALL of VSCode (every window, all groups)
#   dev kill <port>...     kill whatever is listening on the given TCP port(s)
#   dev status             list the group's projects and which are running
#   dev menu               interactive picker (also shown when you run just `myapp`)
#   dev code [names...]    just open the folder(s) in VSCode (no servers)
#   dev config             open the scripts folder (all configs) in VSCode to edit
#   dev wrap <name>        make a dedicated command + starter config for a new group
#   dev help               show this help
#
# Use a different group without its command:  dev -c <name> <command>  (e.g. dev -c myapp up)
# Make a dedicated command for a group:        dev wrap <name>   (then run: <name> up)
#
set -euo pipefail

# Resolve this script's real location (following symlinks) so it works from PATH.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  _dir="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$_dir/$SOURCE" ;; esac
done
SELFDIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# Optional leading -c/--config <name|path> selects a different config (its own group).
_cfg_arg=""
if [ "${1:-}" = "-c" ] || [ "${1:-}" = "--config" ]; then
  if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
    echo "Error: -c/--config requires a group name or config path" >&2
    exit 1
  fi
  _cfg_arg="$2"; shift 2
fi
# Multi-call: if invoked under a name other than 'dev' (e.g. a symlink 'myapp'),
# use that name's config — so `myapp up` == `dev -c myapp up`.
_invoked="$(basename "${0:-dev}")"; _invoked="${_invoked%.sh}"
if [ -z "$_cfg_arg" ] && [ "$_invoked" != "dev" ]; then
  _cfg_arg="$_invoked"
fi
if [ -n "$_cfg_arg" ]; then
  case "$_cfg_arg" in
    */*|*.json) CONFIG="$_cfg_arg" ;;
    *)          CONFIG="$SELFDIR/$_cfg_arg.config.json" ;;
  esac
else
  CONFIG="${DEV_CONFIG:-$SELFDIR/dev.config.json}"
fi

die() { echo "Error: $*" >&2; exit 1; }

BASE=""
SESSION=""
MODE=""
PIDDIR="$SELFDIR/.dev-pids"   # tracks each running server's PID so `down <name>` can stop one
LOGDIR="$SELFDIR/.dev-logs"   # headless (`run`) mode writes each server's output here

# Commands that read projects call this; it validates the config and sets BASE + SESSION.
# Project base dir: config "root" (absolute, or relative to the config file); else the config's own dir.
load_config() {
  if [ ! -f "$CONFIG" ]; then
    echo "Error: config not found: $CONFIG" >&2
    echo "Available groups in $SELFDIR:" >&2
    for f in "$SELFDIR"/*.config.json; do
      [ -e "$f" ] || continue
      echo "  $(basename "$f" .config.json)   (run: $(basename "$f" .config.json) up)" >&2
    done
    exit 1
  fi
  # Node require() interprets an unprefixed relative filename as a package name.
  # Normalize paths once so -c ./file.json, -c file.json, and DEV_CONFIG all work.
  CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
  BASE="$(node -e '
    const path = require("path");
    const cfg = require(process.argv[1]);
    const cfgdir = process.argv[2];
    const r = cfg.root;
    console.log(!r ? cfgdir : (path.isAbsolute(r) ? r : path.resolve(cfgdir, r)));
  ' "$CONFIG" "$(cd "$(dirname "$CONFIG")" && pwd)")"
  SESSION="$(node -e 'console.log(require(process.argv[1]).session || "dev")' "$CONFIG")"
  MODE="$(node -e 'console.log(require(process.argv[1]).mode || "vscode")' "$CONFIG")"
}

# Build the pid-tracked, exec-wrapped command for a project (same in every run mode).
# If a port is given, free it right before the server starts.
wrap_cmd() {   # <name> <command> [port]
  local pf="$PIDDIR/$SESSION-$1.pid" pk="" quoted_dir quoted_pf
  printf -v quoted_dir '%q' "$PIDDIR"
  printf -v quoted_pf '%q' "$pf"
  [ -n "${3:-}" ] && pk="kill \$(lsof -ti tcp:$3 2>/dev/null) 2>/dev/null; "
  printf "mkdir -p %s; echo \$\$ > %s; %sexec %s" "$quoted_dir" "$quoted_pf" "$pk" "$2"
}

# Print selected projects as TSV:  name <TAB> abspath <TAB> command <TAB> port <TAB> workspace(1|"")
# No filters -> only projects with "isMain": true (or all, if none are flagged).
# Filter "all"/"--all" -> every project. A filter naming a "groups" key expands to that
# group's members (exact); any other filter matches project names by substring.
select_projects() {
  node -e '
    const path = require("path");
    const cfg = require(process.argv[1]);
    const base = process.argv[2];
    const filters = process.argv.slice(3);
    const groups = cfg.groups || {};
    const all = cfg.projects;
    const wantAll = filters.some(f => f === "all" || f === "--all");
    let sel;
    if (wantAll) sel = all;
    else if (filters.length) sel = all.filter(p => filters.some(f =>
      groups[f] ? groups[f].includes(p.name) : p.name.includes(f)
    ));
    else sel = all.some(p => p.isMain) ? all.filter(p => p.isMain) : all;
    for (const p of sel) {
      const abs = path.isAbsolute(p.path) ? p.path : path.resolve(base, p.path);
      // Fields are joined with the Unit Separator (char 31), not TAB. TAB is IFS
      // whitespace, so bash `read` collapses repeated tabs and swallows an empty field
      // (e.g. an omitted port), shifting later fields. Char 31 is non-whitespace: empties
      // survive. Every reader below uses IFS=$'\037' to match.
      process.stdout.write([p.name, abs, p.command, p.port == null ? "" : p.port, p.workspace ? "1" : ""].join(String.fromCharCode(31)) + "\n");
    }
  ' "$CONFIG" "$BASE" "$@"
}

# Open each given target in its own VSCode window. A target is a folder (its own window)
# or a .code-workspace file (a multi-root window holding several folders).
open_vscode() {
  [ $# -ge 1 ] || return 0
  if [ -n "${DEV_NO_VSCODE:-}" ]; then echo "DEV_NO_VSCODE set — not opening the editor."; return; fi
  local opener
  if command -v code >/dev/null 2>&1; then opener=code
  elif [ -d "/Applications/Visual Studio Code.app" ]; then opener=app
  else
    echo "Note: VSCode not found — skipping editor open." >&2
    echo "      Install VSCode, or its 'code' CLI (Command Palette > Shell Command: Install 'code' command in PATH)." >&2
    return
  fi
  # VSCode merges folders opened too close together into one window, especially while it
  # is still cold-starting. `code -n` asks for a new window each time; the trick is to not
  # fire the next open until the app is actually up. Tune with DEV_OPEN_DELAY (gap between
  # windows) / DEV_BOOT_DELAY (settle time after a cold start) — both in seconds.
  local gap="${DEV_OPEN_DELAY:-1.5}"
  local running=1
  # Pattern must not contain spaces — `pgrep -f "a b"` doesn't match here.
  pgrep -f "MacOS/Code" >/dev/null 2>&1 || running=0
  local d i=0
  for d in "$@"; do
    [ -e "$d" ] || continue
    [ "$i" -gt 0 ] && sleep "$gap"
    if [ "$opener" = code ]; then code -n "$d"; else open -a "Visual Studio Code" "$d"; fi
    # After a cold start, don't open the next folder until the app has finished booting,
    # otherwise VSCode folds it into the first window. Poll for the process, then settle.
    if [ "$i" = 0 ] && [ "$running" = 0 ]; then
      local waited=0 limit="${DEV_BOOT_TIMEOUT:-30}"
      until pgrep -f "MacOS/Code" >/dev/null 2>&1; do
        sleep 0.5; waited=$((waited + 1))
        [ "$waited" -ge $((limit * 2)) ] && break
      done
      sleep "${DEV_BOOT_DELAY:-4}"
    fi
    i=$((i + 1))
  done
}

# Write a multi-root <session>.code-workspace holding the given folders and print its path.
# Opening that file puts every folder in ONE VSCode window; each folder's tasks.json still
# auto-runs its server. Overwritten on each run; folders use absolute paths.
make_workspace_file() {
  local wsfile="$BASE/$SESSION.code-workspace"
  printf '%s\n' "$@" | node -e '
    const fs = require("fs");
    const out = process.argv[1];
    const folders = fs.readFileSync(0, "utf8").split("\n").filter(Boolean).map(p => ({ path: p }));
    fs.writeFileSync(out, JSON.stringify({ folders, settings: {} }, null, 2) + "\n");
  ' "$wsfile"
  printf '%s\n' "$wsfile"
}

# Write <dir>/.vscode/tasks.json so VSCode auto-runs the dev command on folder open.
# Won't clobber a pre-existing tasks.json that we didn't create.
write_task() {
  local name="$1" dir="$2" cmdline="$3" port="${4:-}"
  [ -d "$dir" ] || { echo "skip $name: directory not found ($dir)" >&2; return; }
  # Wrap the command so the running server records its PID; `down <name>` reads it.
  local wrapped; wrapped="$(wrap_cmd "$name" "$cmdline" "$port")"
  if node -e '
      const fs = require("fs"), path = require("path");
      const [dir, name, cmd] = process.argv.slice(1);
      const vdir = path.join(dir, ".vscode");
      const file = path.join(vdir, "tasks.json");
      const label = "dev: " + name;
      if (fs.existsSync(file) && !fs.readFileSync(file, "utf8").includes(label)) process.exit(3);
      fs.mkdirSync(vdir, { recursive: true });
      const tasks = { version: "2.0.0", tasks: [ {
        label, type: "shell", command: cmd,
        options: { cwd: "${workspaceFolder}" },
        presentation: { reveal: "always", panel: "dedicated", focus: false },
        runOptions: { runOn: "folderOpen" },
        problemMatcher: []
      } ] };
      fs.writeFileSync(file, JSON.stringify(tasks, null, 2) + "\n");
    ' "$dir" "$name" "$wrapped"; then
    echo "configured $name  ($cmdline)"
  else
    echo "! $name: $dir/.vscode/tasks.json exists and isn't ours — left it untouched." >&2
    echo "   Add a task running '$cmdline' with \"runOn\":\"folderOpen\", or delete that file and re-run." >&2
  fi
}

# `up` runs the group's configured mode; the explicit commands force a backend.
cmd_up()     { load_config; case "$MODE" in warp) run_warp "$@";; run|bg|headless) run_bg "$@";; *) run_vscode "$@";; esac; }
cmd_vscode() { load_config; run_vscode "$@"; }
cmd_warp()   { load_config; run_warp "$@"; }
cmd_run()    { load_config; run_bg "$@"; }

# --- VSCode mode: each project in its own window, server in its integrated terminal ---
run_vscode() {
  local matched=0
  local dirs=() ws_dirs=()
  while IFS=$'\037' read -r name dir cmdline port ws; do
    matched=1
    # Projects flagged "workspace": true share one multi-root window; the rest get their own.
    if [ "$ws" = 1 ]; then ws_dirs+=("$dir"); else dirs+=("$dir"); fi
    if [ -z "$cmdline" ]; then
      echo "$name: no \"command\" in config — opening VSCode only"
      continue
    fi
    write_task "$name" "$dir" "$cmdline" "$port"
  done < <(select_projects "$@")
  [ "$matched" = 1 ] || die "no projects matched: $*"
  [ "$(( ${#dirs[@]} + ${#ws_dirs[@]} ))" -gt 0 ] || die "nothing runnable in selection"
  local targets=()
  if [ "${#ws_dirs[@]}" -gt 0 ]; then
    local wsfile; wsfile="$(make_workspace_file "${ws_dirs[@]}")"
    echo "workspace: ${#ws_dirs[@]} project(s) share one window ($wsfile)"
    targets+=("$wsfile")
  fi
  [ "${#dirs[@]}" -gt 0 ] && targets+=("${dirs[@]}")
  open_vscode "${targets[@]}"
  echo
  echo "Each project opened in VSCode; its dev server runs in an integrated terminal."
  echo "First time only: VSCode asks 'Allow Automatic Tasks' — click Allow."
  echo "Stop one: $_invoked down <name>.   Stop all: $_invoked down"
}

# --- Warp mode: generate a Warp launch config with native split panes, then open it ---
run_warp() {
  [ -d /Applications/Warp.app ] || die "Warp not installed (/Applications/Warp.app)"
  mkdir -p "$PIDDIR" "$HOME/.warp/launch_configurations"
  local data="" matched=0 count=0 name dir cmdline port wrapped
  while IFS=$'\037' read -r name dir cmdline port ws; do
    matched=1
    [ -z "$cmdline" ] && { echo "skip $name: no command"; continue; }
    wrapped="$(wrap_cmd "$name" "$cmdline" "$port")"
    data+="$name"$'\t'"$dir"$'\t'"$wrapped"$'\n'
    count=$((count + 1))
  done < <(select_projects "$@")
  [ "$matched" = 1 ] || die "no projects matched: $*"
  [ "$count" -ge 1 ] || die "nothing runnable in selection"

  local out="$HOME/.warp/launch_configurations/$SESSION.yaml"
  printf '%s' "$data" | node -e '
    const fs = require("fs");
    const sess = process.argv[1], out = process.argv[2], base = process.argv[3];
    const q = s => JSON.stringify(s);   // JSON double-quoted scalars are valid YAML
    const rows = fs.readFileSync(0, "utf8").split("\n").filter(Boolean)
      .map(l => { const [n, d, c] = l.split("\t"); return { n, d, c }; });
    let s = "---\n";
    s += "name: " + q(sess) + "\n";
    // active_tab_index 1 -> land on the "work" tab (the 2nd tab)
    s += "windows:\n  - active_tab_index: 1\n    tabs:\n";
    // tab 1: the servers as split panes
    s += "      - title: " + q(sess + " logs") + "\n";
    s += "        layout:\n          split_direction: vertical\n          panes:\n";
    for (const p of rows) {
      s += "            - cwd: " + q(p.d) + "\n";
      s += "              commands:\n";
      s += "                - exec: " + q(p.c) + "\n";
    }
    // tab 2: a free shell in the group root to work in
    s += "      - title: \"work\"\n";
    s += "        layout:\n          cwd: " + q(base) + "\n";
    fs.writeFileSync(out, s);
  ' "$SESSION" "$out" "$BASE"
  echo "wrote Warp launch config: $out  ($count pane(s))"
  if [ -n "${DEV_NO_OPEN:-}" ]; then return; fi
  if open "warp://launch/$SESSION" 2>/dev/null; then
    echo "opening in Warp…"
  else
    echo "Open in Warp: Command Palette (Cmd-P) > 'Launch Configuration' > $SESSION"
  fi
}

# --- Headless mode: run each server in the background, output to a log file, no editor ---
# Same PID tracking as the other modes, so `status` and `down` work unchanged.
run_bg() {
  mkdir -p "$PIDDIR" "$LOGDIR"
  local matched=0 runnable=0 started=0 name dir cmdline port ws wrapped log pf pid
  while IFS=$'\037' read -r name dir cmdline port ws; do
    matched=1
    [ -z "$cmdline" ] && { echo "skip $name: no command"; continue; }
    [ -d "$dir" ]     || { echo "skip $name: directory not found ($dir)" >&2; continue; }
    runnable=$((runnable + 1))
    pf="$PIDDIR/$SESSION-$name.pid"
    if [ -f "$pf" ] && pid="$(cat "$pf" 2>/dev/null)" && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$name: already running (pid $pid) — skipping"; continue
    fi
    wrapped="$(wrap_cmd "$name" "$cmdline" "$port")"
    log="$LOGDIR/$SESSION-$name.log"
    # Subshell: cd into the project, then `exec nohup bash -c` so the running server keeps
    # $! as its PID (nohup and bash both exec through) and survives the terminal closing.
    ( cd "$dir" && exec nohup bash -c "$wrapped" ) >"$log" 2>&1 &
    pid=$!
    echo "started $name (pid $pid)  →  $log"
    started=$((started + 1))
  done < <(select_projects "$@")
  [ "$matched" = 1 ] || die "no projects matched: $*"
  [ "$runnable" -ge 1 ] || die "nothing runnable in selection (no project has a \"command\")"
  if [ "$started" = 0 ]; then echo "all selected server(s) already running — use $_invoked status to check."; return 0; fi
  echo
  echo "$started server(s) running in the background. Tail a log: tail -f '$LOGDIR/$SESSION-<name>.log'"
  echo "Check: $_invoked status.   Stop one: $_invoked down <name>.   Stop all: $_invoked down all"
}

cmd_code() {
  load_config
  local dirs=() ws_dirs=()
  while IFS=$'\037' read -r name dir cmdline port ws; do
    if [ "$ws" = 1 ]; then ws_dirs+=("$dir"); else dirs+=("$dir"); fi
  done < <(select_projects "$@")
  [ "$(( ${#dirs[@]} + ${#ws_dirs[@]} ))" -gt 0 ] || die "no projects matched: $*"
  local targets=()
  [ "${#ws_dirs[@]}" -gt 0 ] && targets+=("$(make_workspace_file "${ws_dirs[@]}")")
  [ "${#dirs[@]}" -gt 0 ] && targets+=("${dirs[@]}")
  open_vscode "${targets[@]}"
}

cmd_config() {
  open_vscode "$SELFDIR"
  echo "opened the scripts folder ($SELFDIR) — edit the *.config.json files there."
}

# Show which of the group's projects are currently running (by tracked PID).
cmd_status() {
  load_config
  printf "%-12s %-9s %s\n" PROJECT STATE PID
  printf "%-12s %-9s %s\n" "-------" "-----" "---"
  local name dir cmdline port pidfile pid state running=0
  while IFS=$'\037' read -r name dir cmdline port ws; do
    pidfile="$PIDDIR/$SESSION-$name.pid"
    state="stopped"; pid="-"
    if [ -f "$pidfile" ]; then
      pid="$(cat "$pidfile" 2>/dev/null)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        state="RUNNING"; running=$((running + 1))
      else
        pid="-"; rm -f "$pidfile"   # clear a stale record
      fi
    fi
    printf "%-12s %-9s %s\n" "$name" "$state" "$pid"
  done < <(select_projects all)
  echo "($running running — only servers started via '$_invoked up' are tracked)"
}

# Interactive picker: list groups + numbered projects, read a selection, then `up` it.
cmd_menu() {
  load_config
  local names=() cmds=() states=()
  local name dir cmdline port pidfile pid
  while IFS=$'\037' read -r name dir cmdline port ws; do
    names+=("$name"); cmds+=("$cmdline")
    pidfile="$PIDDIR/$SESSION-$name.pid"
    if [ -f "$pidfile" ] && pid="$(cat "$pidfile" 2>/dev/null)" && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      states+=("● running")
    else states+=(""); fi
  done < <(select_projects all)

  local gline
  gline="$(node -e 'const g=(require(process.argv[1]).groups)||{};console.log(Object.entries(g).map(([k,v])=>k+" ("+v.join("+")+")").join("   ")||"(none)")' "$CONFIG")"

  echo
  echo "$SESSION — what do you want to run?"
  echo "Groups:  $gline"
  echo
  local i
  for i in "${!names[@]}"; do
    local tag=""; [ -z "${cmds[$i]}" ] && tag="(no command)"
    printf "  %2d) %-10s %-10s %s\n" "$((i + 1))" "${names[$i]}" "${states[$i]}" "$tag"
  done
  echo
  printf "Select (numbers e.g. 1 3, names, or a group; 'all'=everything, Enter=main, q=quit) > "

  local input; IFS= read -r input || true
  case "$input" in q|quit|Q) echo "cancelled."; return 0 ;; esac

  local picks=() tok idx
  input="${input//,/ }"
  for tok in $input; do
    if [ "$tok" = "all" ] || [ "$tok" = "--all" ]; then picks=(all); break; fi
    if printf '%s' "$tok" | grep -qE '^[0-9]+$'; then
      idx=$((tok - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#names[@]}" ]; then picks+=("${names[$idx]}")
      else echo "  (ignoring out-of-range: $tok)" >&2; fi
    else
      picks+=("$tok")   # a name or a group -> select_projects resolves it
    fi
  done

  echo
  if [ "${#picks[@]}" -eq 0 ]; then cmd_up; else cmd_up "${picks[@]}"; fi
}

# --- Closing individual VSCode windows -------------------------------------------
# VSCode has no AppleScript dictionary and its CLI can't close a window, so we drive
# the accessibility API: read each window's title + active document, then press the
# window's close button. Needs Accessibility permission for the calling terminal.

# List VSCode windows as: title <TAB> active-document-URI (URI may be empty).
# rc 10 = Accessibility not granted; rc 11 = VSCode not running.
# (Note: don't use `pgrep -f` with a pattern containing spaces — it doesn't match here.
# System Events reports the not-running case itself, via the NOTRUNNING sentinel.)
vscode_windows() {
  local out
  out="$(osascript 2>/dev/null <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "Code") then return "NOTRUNNING"
  tell process "Code"
    set acc to ""
    repeat with w in windows
      if (value of attribute "AXSubrole" of w) is "AXStandardWindow" then
        set t to name of w
        if t is missing value then set t to ""
        try
          set d to value of attribute "AXDocument" of w
        on error
          set d to ""
        end try
        if d is missing value then set d to ""
        set acc to acc & t & tab & d & linefeed
      end if
    end repeat
    return acc
  end tell
end tell
APPLESCRIPT
  )" || return 10
  [ "$out" = "NOTRUNNING" ] && return 11
  printf '%s' "$out"
}

# Press a window's close button. The title is passed as an argument (never interpolated
# into the script) so quotes/backslashes in it can't break anything.
close_window_by_title() {
  osascript - "$1" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  set target to item 1 of argv
  tell application "System Events" to tell process "Code"
    repeat with w in windows
      if (name of w is target) then
        click button 1 of w   -- button 1 is AXCloseButton
        return
      end if
    end repeat
  end tell
end run
APPLESCRIPT
}

accessibility_help() {
  echo "Can't close individual windows: Accessibility permission is not granted." >&2
  echo "  Grant it: System Settings > Privacy & Security > Accessibility >" >&2
  echo "  enable your terminal app (Terminal / iTerm / Warp), then retry." >&2
  echo "  Or quit all of VSCode anyway:  $_invoked down --quit-all" >&2
}

# Close the VSCode windows for the given targets; leave the rest alone. A target is a
# project folder (its own window) or a .code-workspace file (a shared multi-root window).
close_windows_for_dirs() {
  [ $# -ge 1 ] || return 0
  local dirs=() bases=() wsfiles=() wsnames=() a d
  for a in "$@"; do
    case "$a" in
      *.code-workspace) wsfiles+=("$a"); wsnames+=("$(basename "$a" .code-workspace)") ;;
      *)                dirs+=("$a"); bases+=("$(basename "$a")") ;;
    esac
  done

  local wins rc=0
  wins="$(vscode_windows)" || rc=$?
  case "$rc" in
    11) echo "VSCode is not running."; return 0 ;;
    10) accessibility_help; return 1 ;;
  esac
  [ -n "$wins" ] || { echo "no VSCode windows found."; return 0; }

  local closed=0 dirty=0 title doc clean root b matched
  while IFS=$'\t' read -r title doc; do
    [ -n "$title" ] || continue
    # A modified editor prefixes the title with "● " (U+25CF + space).
    clean="${title#● }"
    # Default title is "${dirty}${activeEditorShort} — ${rootName}…"; the folder is the
    # text after the last " — " (em dash). VSCode truncates the leading filename, never
    # this suffix. A multi-root workspace's rootName is "<workspace-file-name> (Workspace)".
    root="${clean##* — }"
    matched=""
    for b in ${bases[@]+"${bases[@]}"}; do [ "$root" = "$b" ] && { matched="$b"; break; }; done
    if [ -z "$matched" ]; then
      for b in ${wsnames[@]+"${wsnames[@]}"}; do [ "$root" = "$b (Workspace)" ] && { matched="$b"; break; }; done
    fi
    # When the window has a represented file open, its absolute path is authoritative — it
    # confirms or overrides the name match (so same-named folders can't be confused). That
    # file is a folder's editor, or the .code-workspace file itself for a workspace window.
    if [ -n "$doc" ]; then
      matched=""
      for d in ${dirs[@]+"${dirs[@]}"}; do
        case "${doc#file://}" in "$d"/*) matched="$d"; break ;; esac
      done
      if [ -z "$matched" ]; then
        for a in ${wsfiles[@]+"${wsfiles[@]}"}; do [ "${doc#file://}" = "$a" ] && { matched="$a"; break; }; done
      fi
    fi
    [ -n "$matched" ] || continue
    # The default files.hotExit ("onExit") doesn't cover closing a single window, so a
    # window with unsaved edits would raise a modal save sheet and hang us. Skip it.
    if [ "$clean" != "$title" ]; then
      dirty=$((dirty + 1))
      echo "! kept open (unsaved changes): $clean" >&2
      continue
    fi
    if close_window_by_title "$title"; then
      echo "closed window: $title"; closed=$((closed + 1))
    fi
  done <<< "$wins"

  if [ "$dirty" -gt 0 ]; then
    echo "closed $closed window(s), $dirty kept open (unsaved changes)"
  else
    echo "closed $closed window(s)"
  fi
}

# Every project dir across ALL configured groups (deduped). Used by the umbrella `dev`,
# which has no config of its own.
all_group_dirs() {
  node -e '
    const fs = require("fs"), path = require("path");
    const dir = process.argv[1], out = new Set();
    for (const f of fs.readdirSync(dir).filter(f => f.endsWith(".config.json"))) {
      let cfg;
      try { cfg = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); } catch { continue; }
      const base = cfg.root
        ? (path.isAbsolute(cfg.root) ? cfg.root : path.resolve(dir, cfg.root))
        : dir;
      for (const p of (cfg.projects || [])) {
        if (!p || !p.path) continue;
        out.add(path.isAbsolute(p.path) ? p.path : path.resolve(base, p.path));
      }
      // If any project shares a window, the group also has a <session>.code-workspace to close.
      if ((cfg.projects || []).some(p => p && p.workspace)) {
        out.add(path.join(base, (cfg.session || "dev") + ".code-workspace"));
      }
    }
    for (const d of out) console.log(d);
  ' "$SELFDIR"
}

# Kill a PID and all of its descendants (npm -> node -> ...).
kill_tree() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$kid"; done
  kill "$pid" 2>/dev/null || true
}

# Kill whatever is listening on a TCP port.
kill_port() {
  local port="$1" pids
  pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
  if [ -z "$pids" ]; then echo "port $port: nothing listening"; return 0; fi
  echo "$pids" | xargs kill 2>/dev/null || true
  echo "port $port: killed $(echo "$pids" | tr '\n' ' ')"
}

cmd_kill() {
  [ $# -ge 1 ] || die "usage: $_invoked kill <port> [port...]"
  local p
  for p in "$@"; do kill_port "$p"; done
}

# Stop the selected projects' servers via their tracked PIDs, leaving windows open.
# $1 = "quiet" to skip the "no tracked server" note (bare `down` selects every project,
# and most of them normally aren't running).
stop_group_servers() {
  local quiet=""
  [ "${1:-}" = "quiet" ] && { quiet=1; shift; }
  local any=0 name dir cmdline port pidfile pid
  while IFS=$'\037' read -r name dir cmdline port ws; do
    any=1
    pidfile="$PIDDIR/$SESSION-$name.pid"
    if [ -f "$pidfile" ]; then
      pid="$(cat "$pidfile" 2>/dev/null)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill_tree "$pid"; echo "stopped $name (pid $pid)"
      else
        [ -n "$quiet" ] || echo "$name: not running (clearing stale record)"
      fi
      rm -f "$pidfile"
    elif [ -z "$quiet" ]; then
      echo "$name: no tracked server — it wasn't started by '$_invoked up', or already stopped." >&2
    fi
  done < <(select_projects "$@")
  [ "$any" = 1 ] || die "no projects matched: $*"
}

cmd_down() {
  # Old behaviour, kept as an explicit escape hatch: quit the whole app.
  if [ "${1:-}" = "--quit-all" ] || [ "${1:-}" = "--quit" ]; then
    if command -v osascript >/dev/null 2>&1 && osascript -e 'quit app "Visual Studio Code"' 2>/dev/null; then
      echo "quit VSCode (all windows, every group)"
    else
      echo "VSCode was not running"
    fi
    return
  fi

  # With project name(s) — including "all" — stop just those servers via their tracked
  # PID, leaving VSCode (and other groups' windows) open.
  if [ $# -ge 1 ]; then
    load_config
    stop_group_servers "$@"
    return
  fi

  # Bare `dev` (the umbrella, which has no config): close every group's windows.
  if [ "$_invoked" = "dev" ] && [ -z "$_cfg_arg" ] && [ -z "${DEV_CONFIG:-}" ]; then
    local alldirs=() d
    while IFS= read -r d; do [ -n "$d" ] && alldirs+=("$d"); done < <(all_group_dirs)
    [ "${#alldirs[@]}" -gt 0 ] || die "no groups configured in $SELFDIR"
    close_windows_for_dirs "${alldirs[@]}" || true
    return
  fi

  # Bare `<group> down`: stop this group's servers, then close only its windows.
  # Servers are stopped first so they shut down cleanly, rather than being torn down
  # with their terminal — and so this still does something useful if we can't close
  # windows (no Accessibility permission).
  load_config
  stop_group_servers quiet all
  local dirs=() any_ws=0 name dir cmdline port ws
  while IFS=$'\037' read -r name dir cmdline port ws; do
    dirs+=("$dir")
    [ "$ws" = 1 ] && any_ws=1
  done < <(select_projects all)
  # Flagged projects share one <session>.code-workspace window — target it too.
  [ "$any_ws" = 1 ] && dirs+=("$BASE/$SESSION.code-workspace")
  close_windows_for_dirs "${dirs[@]}" || true
}

# Create a dedicated PATH command for a config group + a starter config if missing.
cmd_wrap() {
  [ $# -ge 1 ] || die "usage: dev wrap <name>"
  local name="$1"
  [ "$name" = "dev" ] && die "'dev' is reserved"
  case "$name" in
    ""|[!a-zA-Z]*|*[!a-zA-Z0-9_-]*) die "name must start with a letter and contain only letters, digits, underscores, or hyphens" ;;
  esac

  local bindir
  if [ -w /opt/homebrew/bin ]; then bindir=/opt/homebrew/bin
  else mkdir -p "$HOME/.local/bin"; bindir="$HOME/.local/bin"; fi
  # Never replace an unrelated command on the user's PATH.
  if [ -e "$bindir/$name" ] || [ -L "$bindir/$name" ]; then
    [ -L "$bindir/$name" ] && [ "$(readlink "$bindir/$name")" = "$SELFDIR/dev.sh" ] \
      || die "command already exists: $bindir/$name (choose another name)"
  else
    ln -s "$SELFDIR/dev.sh" "$bindir/$name"
  fi
  echo "created command:  $bindir/$name -> dev.sh"

  local cfg="$SELFDIR/$name.config.json"
  if [ -f "$cfg" ]; then
    echo "config exists:    $cfg"
  else
    cat > "$cfg" <<JSON
{
  "session": "$name",
  "root": "/absolute/path/to/your/project",
  "projects": [
    { "name": "app", "path": ".", "command": "npm run dev" }
  ]
}
JSON
    echo "starter config:   $cfg   <-- edit root + projects"
  fi
  echo "then run:         $name up"
}

usage() {
  sed -n '3,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    up)               cmd_up "$@" ;;
    vscode)           cmd_vscode "$@" ;;
    warp)             cmd_warp "$@" ;;
    run|bg|serve)     cmd_run "$@" ;;
    down)             cmd_down "$@" ;;
    kill|killport)    cmd_kill "$@" ;;
    status|ls|ps)     cmd_status ;;
    code|open)        cmd_code "$@" ;;
    config|edit)      cmd_config ;;
    wrap)             cmd_wrap "$@" ;;
    menu|pick)        cmd_menu ;;
    "")
      # bare `myapp` in a terminal -> interactive picker; otherwise show help
      if [ "$_invoked" != "dev" ] && [ -t 0 ]; then cmd_menu; else usage; fi ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: $sub" >&2; echo >&2; usage; exit 1 ;;
  esac
}

main "$@"
