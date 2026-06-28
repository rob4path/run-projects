# dev — open projects in VSCode and run their dev servers there

A small CLI that, for a group of projects, **opens each project folder in its own VSCode
window** and **runs its dev server in that window's integrated terminal**, so you see the
live server logs right inside VSCode.

Everything lives in this folder: `~/Documents/Coding/scripts/`
- `dev.sh` — the program.
- `tmm.config.json` — the **teamm** project group (run it as `tmm`).
- `giving.config.json` — the **my-giving** project group (run it as `giving`).
- `<name>.config.json` — one file per additional group you add (run it as `<name>`).

**The command name = the config's filename.** A file `<name>.config.json` is driven by a
`<name>` command (a PATH symlink to `dev.sh`). So `tmm.config.json` → `tmm`,
`giving.config.json` → `giving`. `dev` itself is the umbrella tool (`dev wrap`,
`dev config`, `dev -c <name> …`); it has no group of its own. All these commands are
symlinks to `dev.sh`, so they run from any directory.

> **Where is the `tmm` alias defined? Not in the JSON.** The alias is the *command*,
> created as a symlink on your PATH by `dev wrap`:
> `/opt/homebrew/bin/tmm → …/scripts/dev.sh`. The script sees the name it was invoked as
> (`tmm`) and loads the matching `tmm.config.json`. So renaming the command = renaming the
> file **and** updating the symlink (use `dev wrap <newname>`). The `.json` only describes
> *what* runs, never the command name.

---

## Config file format — `<name>.config.json`

A fully annotated example:

```jsonc
{
  // Label for this group. Used internally (e.g. PID filenames) — NOT the command name.
  // The command name comes from the FILENAME (tmm.config.json -> `tmm`).
  "session": "teamm",

  // Base folder for the group. Every project "path" below is resolved against this.
  // Optional — if omitted, paths resolve against the folder the config file is in.
  // May be absolute (shown here) or relative to the config file.
  "root": "/Users/robertbolohan/Documents/Coding/teamm",

  // How `up` runs the servers (see "Run modes"). Optional, default "vscode".
  //   "vscode" — each project in its own VSCode window (server in its terminal)
  //   "warp"   — Warp opens a window with native split panes (all logs together)
  "mode": "vscode",

  // Optional named subsets. Each key is an alias you can pass to up/down/code,
  // expanding to the listed project names. e.g. `tmm up expo` -> mobile + guest.
  "groups": {
    "main": ["api", "web"],
    "expo": ["mobile", "guest"]
  },

  // The projects this group can open/run. Order here = order things launch.
  "projects": [
    {
      // Short id you type in commands (`tmm down web`). Also used as the VSCode task
      // label and the PID filename. Keep it unique within the group.
      "name": "web",

      // Folder to open. Relative to "root" above, or an absolute path for a project
      // located anywhere else on disk.
      "path": "teamm-web",

      // The dev command, run in the project's VSCode integrated terminal.
      // OMIT this field to make the project openable but not runnable — `up` skips it
      // (handy for things like an e2e/test folder).
      "command": "npm start",

      // Optional. If any project sets "isMain": true, then `tmm up` with NO names runs
      // only the isMain ones. `tmm up all` ignores this and runs everything.
      // Defaults to false when omitted.
      "isMain": true,

      // Optional TCP port. If set, whatever is listening on it is killed right before
      // this server starts (clears a stale process holding the port).
      "port": 8888
    }
  ]
}
```

| Field | Where | Required | Purpose |
|---|---|---|---|
| `session` | top | no (defaults to `dev`) | Internal label for the group (PID file prefix). Not the command name. |
| `root` | top | no (defaults to config's folder) | Base dir that project `path`s resolve against. |
| `mode` | top | no (default `vscode`) | How `up` runs servers: `vscode` or `warp` (see Run modes). |
| `groups` | top | no | Named subset aliases → lists of project `name`s. |
| `projects[].name` | per project | **yes** | Id used in commands, the VSCode task label, and PID file. |
| `projects[].path` | per project | **yes** | Folder to open (relative to `root`, or absolute). |
| `projects[].command` | per project | no | Dev command to run. Omit → project is skipped by `up`. |
| `projects[].isMain` | per project | no | Marks a default project for bare `up`. |
| `projects[].port` | per project | no | TCP port to free (kill its listener) right before the server starts. |

> `.config.json` files use strict JSON (the comments above are just for illustration —
> don't put `//` comments in your real file). Every list/object item needs a comma
> except the last one.

---

## Run modes

`up` starts a group's servers one of two ways, picked by the config's `mode` (default
`vscode`). Force a mode regardless of config with `<group> vscode` or `<group> warp`. Both
modes record each server's PID, so `status` and `down <name>` work the same in either.

**`vscode`** (default) — each project opens in its **own VSCode window**; its dev server
runs in that window's integrated terminal (logs inside VSCode). Implemented by writing a
small `.vscode/tasks.json` (`runOn: folderOpen`) into each project folder.
- First time per machine VSCode asks **"Allow Automatic Tasks"** → *Allow* (or Command
  Palette → *Tasks: Manage Automatic Tasks*). Until allowed, the server won't auto-start.
- If a project already has its own `tasks.json`, `dev` won't overwrite it — it warns and
  leaves it alone.

**`warp`** — generates a Warp launch configuration at
`~/.warp/launch_configurations/<session>.yaml` and opens it, so **Warp** shows a window
with two tabs: **`<group> logs`** (native split panes, one per server, mouse-resizable) and
**`work`** (a free shell in the group root, focused on open). Switch tabs with `Cmd+]` /
`Cmd+[` or click. Warp owns the panes; `down`/`status` still work via the recorded PIDs,
but per-project restart is manual. Warp only.

---

## Prerequisites (one-time)

- **Node** — already installed (used to read the config and write the run files).
- **VSCode** (default mode) — with the `code` CLI on PATH preferred (Command Palette →
  *Shell Command: Install 'code' command in PATH*); otherwise falls back to VSCode.app.
- **Warp** (for `warp` mode) — install Warp.app.

---

## Commands

Drive the **teamm** group with `tmm`, the **my-giving** group with `giving`. Every group
command takes the same subcommands (shown here as `<group>`):

```bash
<group>                  # (no command) interactive picker — lists groups + numbered
                         #   projects; choose by number/name/group, 'all', or Enter=main
<group> up               # run MAIN projects using the group's mode (see "isMain")
<group> up all           # run every project in the group
<group> up api web       # only a subset (match by name or group alias)
<group> vscode [names]   # force VSCode mode (a window per project)
<group> warp [names]     # force Warp mode (native split panes, all logs in one window)
<group> status           # list the group's projects and which are running
<group> down <name>      # stop just that one server
<group> down all         # stop ALL of this group's servers
<group> down             # quit ALL of VSCode (every window, all groups)
<group> kill 8888 3000   # kill whatever is listening on those TCP ports
<group> code mobile      # just open folder(s) in VSCode; don't run anything
<group> config           # open the scripts folder to edit configs
dev help                 # full help
```

Examples for your projects:
```bash
tmm up                 # teamm: only the isMain projects (api, web)
tmm up all             # teamm: every project (api, web, mobile, guest)
tmm up expo            # teamm group alias: mobile + guest
tmm down web           # stop just the web server
giving up              # my-giving: its isMain projects
```

### Interactive picker

Run a group command with **no arguments** (in a terminal) to get a menu:

```
$ tmm
teamm — what do you want to run?
Groups:  main (api+web)   expo (mobile+guest)

   1) api        ● running
   2) web
   3) mobile
   4) guest
   5) e2e                    (no command)

Select (numbers e.g. 1 3, names, or a group; 'all'=everything, Enter=main, q=quit) >
```
Type any mix of **numbers** (`1 3` or `1,3`), **project names**, or a **group name**
(`expo`); `all` runs everything, **Enter** runs the `isMain` projects, `q` cancels. The
chosen projects then launch exactly like `<group> up …`. Running projects are marked
`● running`. (Also available explicitly as `<group> menu`.)

### Which projects run by default — `isMain`

`<group> up` with no names runs only the projects flagged `"isMain": true` in the config:
```jsonc
{ "name": "api", "path": "teamm-api", "command": "npm run dev", "isMain": true },
{ "name": "mobile", "path": "teamm-mobile", "command": "npm start", "isMain": false }
```
Run everything with `<group> up all`, or name specific projects/groups. (If no project is
flagged `isMain`, `up` with no names runs them all — backward compatible.)

### Stopping (works in either mode)
- One server → `<group> down <name>` (e.g. `tmm down web`). Each server records its PID
  when it starts; `down` reads it and stops that process tree. Only stoppable this way
  after you launched it via `<group> up`/`vscode`/`warp`.
- All of one group's servers → `<group> down all`. Stops every tracked server but leaves
  VSCode/Warp windows open.
- Quit the editor entirely → `<group> down` with **no name**: quits VSCode (closes **all**
  its windows — macOS can't quit just one; use `down all` to only stop this group's servers).
- You can also close a Warp pane or click the trash icon on a VSCode terminal directly.

### Optional env toggles
```bash
DEV_NO_VSCODE=1 tmm up        # only write the task files; don't open the editor
DEV_OPEN_DELAY=2.5 tmm up api web  # seconds between opening windows (default 1.5;
                              #   raise if VSCode merges them into one window, 0 = no gap)
DEV_BOOT_DELAY=4 tmm up       # extra seconds after the 1st window if VSCode was cold (default 3)
dev -c giving up              # same as `giving up` (pick a config by name)
DEV_CONFIG=/path/x.json dev up  # use an exact config file
```

> Note: `down` quits **all** VSCode windows (the macOS CLI can't target one window). If
> you keep unrelated things open in VSCode, just close the specific server windows
> instead.

---

## Add a project to an existing group

Edit that group's config (e.g. `tmm.config.json` or `giving.config.json`) and add one
entry to `projects`:

```jsonc
{ "name": "booking", "path": "booking-engine", "command": "npm start" }
```
- **`name`** — short label you type in commands (`tmm up booking`).
- **`path`** — relative to the group's `root`, **or** an absolute path for a project
  located anywhere else.
- **`command`** — its dev command.
- JSON rule: every entry needs a trailing comma **except the last one**.

Then `tmm up booking` configures and opens it.

---

## Group some projects (named subsets)

Add a `groups` map to a config to name a subset, then launch it with that name:

```jsonc
{
  "session": "teamm",
  "root": "/Users/robertbolohan/Documents/Coding/teamm",
  "groups": {
    "web-stack": ["api", "web"],
    "expo":      ["mobile", "guest"]
  },
  "projects": [ /* ... */ ]
}
```
```bash
tmm up web-stack         # opens api + web
tmm up expo             # opens mobile + guest
tmm up expo api         # mix a group with a single project -> mobile, guest, api
```
Each project still gets its own VSCode window. A name that matches a group expands to its
members; any other name still matches projects by substring. Currently defined:
**teamm** → `web-stack`, `expo`; **my-giving** (`giving`) → `front` (admin+mobile),
`back` (api).

## Set up a brand-new project group — step by step

Say you have a project at `~/Documents/Coding/myapp` and want a `myapp` command.

1. **Create the command + a starter config:**
   ```bash
   dev wrap myapp
   ```
   Makes a `myapp` command on your PATH and a `myapp.config.json` here (if missing).

2. **Edit `~/Documents/Coding/scripts/myapp.config.json`:**
   ```jsonc
   {
     "session": "myapp",
     "root": "/Users/robertbolohan/Documents/Coding/myapp",
     "projects": [
       { "name": "api", "path": "backend",  "command": "npm run dev" },
       { "name": "web", "path": "frontend", "command": "npm run dev" }
     ]
   }
   ```
   - `session` is just a label for the group (keep it unique).
   - `root` is the project's base folder; `path`s are relative to it.

3. **Run it:**
   ```bash
   myapp up        # open each folder + run its server in VSCode
   myapp down
   ```

(You don't have to wrap — `dev -c myapp up` also works without a dedicated command.)

---

## Configured groups

### teamm — `tmm`  (mode: `vscode`)
`root: ~/Documents/Coding/teamm` — `tmm up` opens each project in its own VSCode window.
| name | folder | command |
|---|---|---|
| api | teamm-api | npm run dev |
| web | teamm-web | npm start |
| mobile | teamm-mobile | npm start |
| mobile:ios | teamm-mobile | npm run ios |
| guest | teamm-guest | npm start |
| guest:ios | teamm-guest | npm run ios |

### my-giving — `giving`  (mode: `vscode`)
`root: ~/Documents/Coding/my-giving`
| name | folder | command |
|---|---|---|
| api | my-giving-api | npm run dev |
| admin | my-giving-admin | npm run dev |
| mobile | my-giving-mobile-sim | npm run dev |

(`my-giving-e2e` is a Playwright test runner, not a dev server, so it's not included —
run its tests directly with `npm test` in that folder when needed.)

---

## Troubleshooting

- **Server didn't start in VSCode** → you probably haven't allowed automatic tasks yet:
  Command Palette → *Tasks: Manage Automatic Tasks* → *Allow Automatic Tasks*, then
  reload the window (Command Palette → *Developer: Reload Window*).
- **"already has a tasks.json … left it untouched"** → that project had its own
  `tasks.json`. Open it and add a task with `"runOn": "folderOpen"` running your dev
  command, or delete the file and re-run `<group> up <name>`.
- **VSCode didn't open at all** → install the `code` CLI (see Prerequisites); it
  otherwise falls back to VSCode.app.
- **`no projects matched: …`** → the name filter didn't match any `name` in the config.
- **Want to re-run a server in an already-open window** → reload the window (Command
  Palette → *Developer: Reload Window*), which re-triggers the folder-open task.
