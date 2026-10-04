# run-projects

Start a group of local development projects with one command. Run servers in **VS Code**, in **Warp split panes**, or in the **background** with log files. Check their status and stop them individually or as a group.

The launcher is a single Bash script with JSON configuration. It can run Node.js, Python, Flutter, or any other project with a shell command.

## Requirements

- **macOS** and Bash (the built-in Bash works). Editor/window integration uses macOS tools; Windows and Linux are not currently supported.
- **Node.js** available as `node`, used to read JSON and generate editor files. The launcher has no npm dependencies.
- Your projects' own runtimes and dependencies, installed separately.
- **VS Code** for `vscode` mode, or **Warp** installed at `/Applications/Warp.app` for `warp` mode. Neither is needed for background mode.
- `lsof` if you configure a port to free before starting a server.

For VS Code, enable the `code` command through the Command Palette: **Shell Command: Install 'code' command in PATH**. The script also falls back to `/Applications/Visual Studio Code.app`.

## Quick start

```bash
git clone https://github.com/rob4path/run-projects.git
cd run-projects
chmod +x dev.sh
cp example.config.json myapp.config.json
```

Edit `myapp.config.json` before starting anything. Set `root` to your projects' base directory, and change each project's `path` and `command`. Remove entries you do not need.

For example, if your folders look like this:

```text
Coding/
├── run-projects/
│   ├── dev.sh
│   └── myapp.config.json
└── myapp/
    ├── backend/
    ├── frontend/
    ├── mobile/
    └── docs/
```

The example's `"root": "../myapp"` already resolves to the right directory. Relative roots resolve from the **config file's directory**, regardless of where you run the command. Use an absolute root if your projects live elsewhere. `~` and `$HOME` inside JSON paths are not expanded.

Check the configuration, then start the default projects:

```bash
./dev.sh -c myapp status
./dev.sh -c myapp up          # starts api + web in one shared VS Code window
./dev.sh -c myapp down all    # stops tracked servers; leaves windows open
```

On the first VS Code launch, allow automatic tasks when prompted. You can also use **Tasks: Manage Automatic Tasks → Allow Automatic Tasks**, then reload the window. Server logs appear in integrated terminals.

Prefer background servers with no editor?

```bash
./dev.sh -c myapp run
./dev.sh -c myapp status
tail -f .dev-logs/myapp-api.log
# Press Ctrl+C to stop tailing; the server keeps running.
./dev.sh -c myapp down all
```

The example does not create projects or install their dependencies. Each selected project directory must already exist, and its command must work when run from that directory.

## Example JSON

[example.config.json](example.config.json) is a complete, copyable **strict JSON** file with a backend, frontend, optional mobile app, and a docs folder. Local `*.config.json` files are ignored by Git; the example is the only exception.

A smaller configuration for just two servers is:

```json
{
  "session": "myapp",
  "root": "../myapp",
  "mode": "vscode",
  "projects": [
    {
      "name": "api",
      "path": "backend",
      "command": "npm run dev",
      "isMain": true
    },
    {
      "name": "web",
      "path": "frontend",
      "command": "npm run dev",
      "isMain": true
    }
  ]
}
```

Save this as `myapp.config.json`. JSON does not allow comments or trailing commas.

### Fields

| Field | Required | Meaning / default |
| --- | --- | --- |
| `session` | No | Label for PID files, logs, workspaces, and Warp launch configs. Defaults to `dev`. Use a different label for each group to avoid collisions. |
| `root` | No | Base folder for project paths. Absolute, or relative to the config file. Defaults to the config file's directory. |
| `mode` | No | `vscode` (default), `warp`, or `run`. Used by `up`; an explicit mode command overrides it. |
| `groups` | No | Object mapping subset names to arrays of exact project names. |
| `projects` | Yes | Array of project objects, launched in the order listed. |
| `projects[].name` | Yes | Unique project identifier used for selection, tasks, logs, and PID files. |
| `projects[].path` | Yes | Project directory relative to `root`, or an absolute directory. Use `.` for the root itself. |
| `projects[].command` | No | Shell command executed in the project directory. Without it, VS Code opens the folder only; Warp/background modes skip it. |
| `projects[].isMain` | No | Defaults to `false`. If any project sets it to `true`, bare `up` selects only those projects. Otherwise bare `up` selects all. |
| `projects[].workspace` | No | Defaults to `false`. In VS Code mode, selected projects with `true` share a multi-root window; others get separate windows. Also applies to `code`. |
| `projects[].port` | No | Optional TCP port to free before running the command. This terminates processes using that port; it does **not** set the server's port. Omit unless you need it. |

Use simple names such as `myapp`, `api`, and `web`; avoid slashes, quotes, and whitespace in session/project identifiers. Commands are executed as shell code, so use configurations you trust. For straightforward PID tracking, prefer one foreground command (for example, `npm run dev`), rather than backgrounding it with `&`.

### How the full example behaves

- `up` starts `api` and `web`, since both have `isMain: true`. They share a VS Code window because both have `workspace: true`.
- `up all` also starts `mobile` in a separate window and opens `docs` without a server.
- `up frontend` selects the `web` and `mobile` projects.
- `up fullstack` selects `api` and `web`.
- `code docs` opens the docs folder.

`isMain` controls the default selection; it does not stop you from selecting another project explicitly.

## Optional commands on your PATH

You can always use `./dev.sh -c myapp ...`. To call it from any directory, create a `dev` symlink in your own bin directory:

```bash
# Run from the run-projects directory.
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/dev.sh" "$HOME/.local/bin/dev"
export PATH="$HOME/.local/bin:$PATH"
```

Add the `export PATH` line to your shell startup file (for example, `~/.zshrc` on macOS) to keep it in new terminals. If a command named `dev` already exists, use a different symlink name and pass `-c myapp` explicitly.

Give a project group its own command:

```bash
dev wrap myapp     # creates the myapp command; keeps an existing config
myapp status
myapp up
myapp down all
```

`wrap` places the symlink in `/opt/homebrew/bin` if it is writable, otherwise in `~/.local/bin`. Ensure the chosen directory is on your PATH. If the config does not exist, `wrap` creates a starter config beside `dev.sh`; edit its root and projects before running it.

The **command name selects the config filename**: `myapp` loads `myapp.config.json`. The JSON `session` is a runtime label and does not create a command.

Keep the checkout in place after installing symlinks; moving or deleting it breaks those commands. To uninstall a symlink, remove only the link you created, for example `rm "$HOME/.local/bin/dev"`.

## Commands

The table uses `myapp`, installed with `dev wrap myapp`. Without a wrapper, replace `myapp` with `./dev.sh -c myapp`.

| Command | Behavior |
| --- | --- |
| `myapp` / `myapp menu` | Interactive picker: numbers, project names, subsets, `all`, Enter for defaults, or `q` to quit. Bare invocation shows the picker only in a terminal. |
| `myapp up [names...]` | Start selected projects in the configured mode. No names selects main projects (or all if none are marked). |
| `myapp up all` | Select every project. |
| `myapp vscode [names...]` | Force VS Code mode. |
| `myapp warp [names...]` | Force Warp mode. |
| `myapp run [names...]` | Force background mode. |
| `myapp status` | List all projects and tracked server PIDs. |
| `myapp down api` | Stop the selected tracked server and its child processes. |
| `myapp down all` | Stop all tracked servers in this group, keeping windows open. |
| `myapp down` | Stop this group's tracked servers and attempt to close its VS Code windows. |
| `myapp down --quit-all` | Quit the entire VS Code app, including unrelated windows. Does not separately stop background or Warp servers. |
| `myapp code [names...]` | Open selected folders/workspaces in VS Code without generating server tasks. Existing automatic tasks may still run. |
| `myapp kill 3000 8080` | Terminate processes using the specified TCP ports. |
| `myapp config` | Open the launcher's folder in VS Code to edit configs. |
| `dev wrap <name>` | Create a group command and a starter config if missing. |
| `dev help` | Show CLI help. |
| `dev down` | Attempt to close configured groups' VS Code windows. Does not separately stop background or Warp servers. |

A group name expands to its exact members. Other selection arguments match project names by **substring**, so `api` also selects a project named `api-worker`. You can mix selections, for example `myapp up frontend api`. `all` overrides other filters. Selection preserves config order.

You can also use an explicit config path or environment variable:

```bash
./dev.sh -c ./myapp.config.json status
DEV_CONFIG=/absolute/path/to/myapp.json ./dev.sh status
```

An explicit `-c` takes precedence over `DEV_CONFIG`. A group wrapper selects its own config.

## Run modes and generated files

**VS Code:** writes `<project>/.vscode/tasks.json` with a `dev: <name>` shell task that runs on folder open. An existing file without that task label is left untouched; a file containing the label is rewritten. Projects marked `workspace: true` also generate `<root>/<session>.code-workspace`, rewritten for the current selection. Allow automatic tasks only in trusted projects.

**Warp:** writes `~/.warp/launch_configurations/<session>.yaml` and opens it. The launch has a logs tab with one pane per runnable project and a work tab with a shell in the group root. Existing launch configuration files with the same session name are overwritten. Stopping tracked servers leaves Warp windows open.

**Background:** starts detached servers with `nohup`. Logs go to `<launcher>/.dev-logs/<session>-<name>.log` and are replaced when that server starts again. Re-running `run` skips a server whose tracked PID is still alive.

All modes record PIDs under `<launcher>/.dev-pids/`. Only servers launched by this tool are tracked. PID state is local and may become stale, especially after a reboot; check the reported process if a status seems wrong.

Logs, PID files, personal configs, and generated workspaces are ignored in this repository. The task/workspace files written into **other project repositories** are governed by those repositories' own `.gitignore` rules.

### Environment options

| Variable | Effect |
| --- | --- |
| `DEV_CONFIG` | Config path when invoked as `dev` / `dev.sh` without `-c`. |
| `DEV_NO_VSCODE=1` | Generate VS Code files without opening the editor. |
| `DEV_OPEN_DELAY` | Seconds between VS Code windows; default `1.5`. |
| `DEV_BOOT_DELAY` | Extra settle time after a cold VS Code start; default `4`. |
| `DEV_BOOT_TIMEOUT` | Maximum seconds to wait for the VS Code process; default `30`. |
| `DEV_NO_OPEN=1` | Generate the Warp launch config without opening it. Warp must still be installed. |

## Troubleshooting

- **Config not found:** copy `example.config.json` to `myapp.config.json` beside `dev.sh` and use `-c myapp`, or provide a path. Bare `dev up` expects `dev.config.json`.
- **Directory not found:** check `root` and `path`. Relative paths start from the config's directory, not your current shell directory. Install the project's dependencies separately.
- **Server did not start in VS Code:** allow automatic tasks, then use **Developer: Reload Window**. Reloading can launch the command again; use `down all` first if an old server is still running.
- **Existing tasks file was left untouched:** add the task to your own `.vscode/tasks.json` manually or use background/Warp mode. Preserve existing tasks you need.
- **No projects matched:** check the project names and subset keys. A subset lists exact project names.
- **Group command not found:** add the directory reported by `dev wrap` to your PATH, or use `./dev.sh -c myapp ...`.
- **Individual windows cannot close:** grant Accessibility access to your terminal in **System Settings → Privacy & Security → Accessibility**. Closing uses window titles/documents and skips windows whose titles indicate unsaved changes. You can instead close them manually. `down all` only stops servers and needs no Accessibility access.

## Contributing

Keep examples generic and do not commit personal configs, logs, environment files, or credentials. To check changes locally:

```bash
bash -n dev.sh
node -e 'JSON.parse(require("fs").readFileSync("example.config.json", "utf8")); console.log("Example JSON is valid")'
./dev.sh help
./dev.sh -c example status
```

Try launch/stop behavior with a temporary project before opening a pull request. Use `DEV_NO_VSCODE=1` to inspect generated tasks without opening windows. Include your macOS version, run mode, command, and a sanitized configuration when reporting a problem.

## License

[MIT](LICENSE). You may use, modify, and redistribute the launcher under the license's terms.
