#!/usr/bin/env bash
#
# dev.sh — run a group of projects' dev servers, in VSCode (default) or Warp.
#
# Each group has its own config <name>.config.json and is run as `<name>` (e.g. `tmm up`,
# `giving up`); `dev` is the umbrella tool. A group's "mode" picks how `up` runs servers:
#   vscode (default) — each project in its own VSCode window, server in its terminal
#   warp             — Warp opens a window with native split panes (all logs together)
#
#   dev up [names...]      run the group's servers using its configured mode
#                          no names -> only projects flagged "isMain": true;  use "all" for every one
#   dev vscode [names...]  force VSCode mode  (ignore the config's mode)
#   dev warp  [names...]   force Warp mode
#   dev down [names...]    stop those servers ("all" = the whole group)
#                          no names -> quit ALL of VSCode (every window, all groups)
#   dev kill <port>...     kill whatever is listening on the given TCP port(s)
#   dev status             list the group's projects and which are running
#   dev menu               interactive picker (also shown when you run just `tmm`/`giving`)
#   dev code [names...]    just open the folder(s) in VSCode (no servers)
#   dev config             open the scripts folder (all configs) in VSCode to edit
#   dev wrap <name>        make a dedicated command + starter config for a new group
#   dev help               show this help
#
# Use a different group without its command:  dev -c <name> <command>  (e.g. dev -c giving up)
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
  _cfg_arg="${2:-}"; shift 2 || true
fi
# Multi-call: if invoked under a name other than 'dev' (e.g. a symlink 'giving'),
# use that name's config — so `giving up` == `dev -c giving up`.
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
  local pf="$PIDDIR/$SESSION-$1.pid" pk=""
  [ -n "${3:-}" ] && pk="kill \$(lsof -ti tcp:$3 2>/dev/null) 2>/dev/null; "
  printf "mkdir -p '%s'; echo \$\$ > '%s'; %sexec %s" "$PIDDIR" "$pf" "$pk" "$2"
}

# Print selected projects as TSV:  name <TAB> abspath <TAB> command
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
      process.stdout.write([p.name, abs, p.command, p.port == null ? "" : p.port].join("\t") + "\n");
    }
  ' "$CONFIG" "$BASE" "$@"
}

# Open each given folder in its own VSCode window.
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
  # VSCode merges folders opened too close together into one window. Space them out so
  # each lands in its own window. Tune with DEV_OPEN_DELAY / DEV_BOOT_DELAY (seconds).
  local gap="${DEV_OPEN_DELAY:-1.5}"
  local running=1
  pgrep -f "Visual Studio Code.app/Contents/MacOS" >/dev/null 2>&1 || running=0
  local d i=0
  for d in "$@"; do
    [ -d "$d" ] || continue
    [ "$i" -gt 0 ] && sleep "$gap"
    if [ "$opener" = code ]; then code -n "$d"; else open -a "Visual Studio Code" "$d"; fi
    # give a cold-starting app time to boot before the next window
    if [ "$i" = 0 ] && [ "$running" = 0 ]; then sleep "${DEV_BOOT_DELAY:-3}"; fi
    i=$((i + 1))
  done
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
cmd_up()     { load_config; case "$MODE" in warp) run_warp "$@";; *) run_vscode "$@";; esac; }
cmd_vscode() { load_config; run_vscode "$@"; }
cmd_warp()   { load_config; run_warp "$@"; }

# --- VSCode mode: each project in its own window, server in its integrated terminal ---
run_vscode() {
  local matched=0
  local dirs=()
  while IFS=$'\t' read -r name dir cmdline port; do
    matched=1
    if [ -z "$cmdline" ]; then
      echo "skip $name: no \"command\" in config (nothing to run)"
      continue
    fi
    dirs+=("$dir")
    write_task "$name" "$dir" "$cmdline" "$port"
  done < <(select_projects "$@")
  [ "$matched" = 1 ] || die "no projects matched: $*"
  [ "${#dirs[@]}" -gt 0 ] || die "nothing runnable in selection"
  open_vscode "${dirs[@]}"
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
  while IFS=$'\t' read -r name dir cmdline port; do
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

cmd_code() {
  load_config
  local dirs=()
  while IFS=$'\t' read -r name dir cmdline port; do dirs+=("$dir"); done < <(select_projects "$@")
  [ "${#dirs[@]}" -gt 0 ] || die "no projects matched: $*"
  open_vscode "${dirs[@]}"
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
  while IFS=$'\t' read -r name dir cmdline port; do
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
  while IFS=$'\t' read -r name dir cmdline port; do
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

cmd_down() {
  # With project name(s) — including "all" — stop just those servers via their tracked
  # PID, leaving VSCode (and other groups' windows) open.
  if [ $# -ge 1 ]; then
    load_config
    local any=0 name dir cmdline port pidfile pid
    while IFS=$'\t' read -r name dir cmdline port; do
      any=1
      pidfile="$PIDDIR/$SESSION-$name.pid"
      if [ -f "$pidfile" ]; then
        pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          kill_tree "$pid"; echo "stopped $name (pid $pid)"
        else
          echo "$name: not running (clearing stale record)"
        fi
        rm -f "$pidfile"
      else
        echo "$name: no tracked server — it wasn't started by '$_invoked up', or already stopped." >&2
      fi
    done < <(select_projects "$@")
    [ "$any" = 1 ] || die "no projects matched: $*"
    return
  fi

  # No name: quit VSCode entirely (stops every server running in it).
  if command -v osascript >/dev/null 2>&1; then
    if osascript -e 'quit app "Visual Studio Code"' 2>/dev/null; then
      echo "closed VSCode (its servers stopped with it)"
    else
      echo "VSCode was not running"
    fi
  else
    echo "osascript not available — quit VSCode manually to stop the servers." >&2
  fi
}

# Create a dedicated PATH command for a config group + a starter config if missing.
cmd_wrap() {
  [ $# -ge 1 ] || die "usage: dev wrap <name>"
  local name="$1"
  [ "$name" = "dev" ] && die "'dev' is reserved"
  case "$name" in */*|*" "*) die "name must be a simple word (no slashes/spaces)";; esac

  local bindir
  if [ -w /opt/homebrew/bin ]; then bindir=/opt/homebrew/bin
  else mkdir -p "$HOME/.local/bin"; bindir="$HOME/.local/bin"; fi
  ln -sf "$SELFDIR/dev.sh" "$bindir/$name"
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
    down)             cmd_down "$@" ;;
    kill|killport)    cmd_kill "$@" ;;
    status|ls|ps)     cmd_status ;;
    code|open)        cmd_code "$@" ;;
    config|edit)      cmd_config ;;
    wrap)             cmd_wrap "$@" ;;
    menu|pick)        cmd_menu ;;
    "")
      # bare `tmm`/`giving` in a terminal -> interactive picker; otherwise show help
      if [ "$_invoked" != "dev" ] && [ -t 0 ]; then cmd_menu; else usage; fi ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: $sub" >&2; echo >&2; usage; exit 1 ;;
  esac
}

main "$@"
