# run-projects

A collection of independent scripts, small apps, and utilities. Each project has its own README, setup instructions, and runtime requirements. Install and run only the tools you need; there is no shared application or root dependency install.

## Projects

| Project | What it does | Requirements | Guide |
| --- | --- | --- | --- |
| Development project launcher | Start, inspect, and stop groups of local development servers in VS Code, Warp, or the background. | macOS, Bash, Node.js | [Setup and usage](projects/dev-launcher/README.md) |
| WhatsApp readable chat export | Export loaded WhatsApp Web messages to a readable offline HTML file, with date filters and optional conversation details. | Browser with Tampermonkey and WhatsApp Web | [Install and export](projects/whatsapp-export/README.md) |

## Repository layout

```text
run-projects/
├── README.md                     # Project directory and collection conventions
├── LICENSE
├── dev.sh                        # Existing launcher entry point
├── example.config.json           # Shareable launcher configuration example
└── projects/
    ├── dev-launcher/
    │   └── README.md             # Full launcher documentation
    └── whatsapp-export/
        ├── README.md
        ├── .gitignore
        └── whatsapp-export.user.js
```

The launcher stays at the repository root for compatibility with existing shell wrappers, relative paths, and personal `*.config.json` files. New utilities belong in their own `projects/<name>/` directory. Project folders are part of this repository, not nested Git repositories.

## Using a project

1. Choose a project from the table above.
2. Read that project's README for requirements and setup.
3. Run its documented commands or install its script. Tools do not depend on each other unless their README explicitly says so.

## Adding a script, app, or utility

1. Create `projects/<short-kebab-case-name>/`.
2. Keep its source, examples, dependency manifest (if needed), and tests together.
3. Add a README covering purpose, requirements, installation, usage, configuration/defaults, output or side effects, limitations, and validation commands.
4. Add project-specific ignore rules for generated files and local data.
5. Add a row to the project table in this README.
6. Run the relevant checks for the changed project.

Avoid introducing shared dependencies or a root build pipeline for unrelated tools. Do not commit personal configuration, secrets, downloaded chat exports, logs, or generated output. Keep examples safe to share.

## Validation

Run from the repository root:

```sh
bash -n dev.sh
node -e 'JSON.parse(require("fs").readFileSync("example.config.json", "utf8")); console.log("Example JSON is valid")'
node --check projects/whatsapp-export/whatsapp-export.user.js
```

See each project's README for behavior checks and known limitations. Syntax checks alone do not verify browser integration or server launch behavior.

## License

[MIT](LICENSE), unless a project explicitly documents a different license for included third-party material.
