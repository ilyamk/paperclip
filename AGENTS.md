# AGENTS.md

Guidance for human and AI contributors working in this repository.

## 1. Purpose

Paperclip is a control plane for AI-agent companies.
The current implementation target is V1 and is defined in `doc/SPEC-implementation.md`.

## 2. Read This First

Before making changes, read in this order:

1. `doc/GOAL.md`
2. `doc/PRODUCT.md`
3. `doc/SPEC-implementation.md`
4. `doc/DEVELOPING.md`
5. `doc/DATABASE.md`

`doc/SPEC.md` is long-horizon product context.
`doc/SPEC-implementation.md` is the concrete V1 build contract.

## 3. Repo Map

```
paperclip/
  server/                    Express REST API and orchestration services
  ui/                        React 19 + Vite board UI
  cli/                       CLI tool (published to npm as `paperclipai`)
  packages/
    db/                      Drizzle schema, migrations, DB clients
    shared/                  Shared types, constants, validators, API path constants
    adapter-utils/           Utilities for agent adapters
    adapters/
      claude-local/          Claude Code adapter
      codex-local/           Codex/OpenAI adapter
      openclaw/              OpenClaw adapter
  skills/                    Agent skill definitions (heartbeat, create-agent, etc.)
  scripts/                   Build/dev/release helper scripts
  src-tauri/                 Tauri v2 desktop app (macOS native wrapper)
  doc/                       Operational and product docs
  docs/                      Mintlify documentation site
  Dockerfile                 Docker production image
  docker-compose.yml         Local Docker setup
```

## 4. Dev Setup (Auto DB)

Use embedded PostgreSQL in dev by leaving `DATABASE_URL` unset.

```sh
pnpm install
pnpm dev
```

This starts:

- API: `http://localhost:3100`
- UI: `http://localhost:3100` (served by API server in dev middleware mode)

Quick checks:

```sh
curl http://localhost:3100/api/health
curl http://localhost:3100/api/companies
```

Reset local dev DB:

```sh
rm -rf ~/.paperclip/instances/default/db
pnpm dev
```

## 5. Core Engineering Rules

1. Keep changes company-scoped.
Every domain entity should be scoped to a company and company boundaries must be enforced in routes/services.

2. Keep contracts synchronized.
If you change schema/API behavior, update all impacted layers:
- `packages/db` schema and exports
- `packages/shared` types/constants/validators
- `server` routes/services
- `ui` API clients and pages

3. Preserve control-plane invariants.
- Single-assignee task model
- Atomic issue checkout semantics
- Approval gates for governed actions
- Budget hard-stop auto-pause behavior
- Activity logging for mutating actions

4. Do not replace strategic docs wholesale unless asked.
Prefer additive updates. Keep `doc/SPEC.md` and `doc/SPEC-implementation.md` aligned.

## 6. Database Change Workflow

When changing data model:

1. Edit `packages/db/src/schema/*.ts`
2. Ensure new tables are exported from `packages/db/src/schema/index.ts`
3. Generate migration:

```sh
pnpm db:generate
```

4. Validate compile:

```sh
pnpm -r typecheck
```

Notes:
- `packages/db/drizzle.config.ts` reads compiled schema from `dist/schema/*.js`
- `pnpm db:generate` compiles `packages/db` first

## 7. Verification Before Hand-off

Run this full check before claiming done:

```sh
pnpm -r typecheck
pnpm test:run
pnpm build
```

If anything cannot be run, explicitly report what was not run and why.

## 8. API and Auth Expectations

- Base path: `/api`
- Board access is treated as full-control operator context
- Agent access uses bearer API keys (`agent_api_keys`), hashed at rest
- Agent keys must not access other companies

When adding endpoints:

- apply company access checks
- enforce actor permissions (board vs agent)
- write activity log entries for mutations
- return consistent HTTP errors (`400/401/403/404/409/422/500`)

## 9. UI Expectations

- Keep routes and nav aligned with available API surface
- Use company selection context for company-scoped pages
- Surface failures clearly; do not silently ignore API errors

## 10. Definition of Done

A change is done when all are true:

1. Behavior matches `doc/SPEC-implementation.md`
2. Typecheck, tests, and build pass
3. Contracts are synced across db/shared/server/ui
4. Docs updated when behavior or commands change

## 11. Tauri Desktop App (macOS)

Paperclip ships as a self-contained macOS desktop app via Tauri v2. The `.app` bundle includes Node.js, the Express server, React UI, all npm dependencies, and embedded PostgreSQL -- no external dependencies required on the target machine.

### Architecture

```
Paperclip.app/Contents/
  MacOS/Paperclip            Tauri Rust binary (native window host)
  Resources/
    icon.icns                App icon
    bundle-app/
      node                   Bundled Node.js 20.x binary (arm64)
      app/
        dist/                Compiled server JS (from server/src via tsc)
        ui-dist/             Built React UI (from ui/ via vite build)
        node_modules/        Production dependencies (via pnpm deploy)
        package.json         Patched server package.json (exports -> dist/)
        start.sh             Standalone launcher script
```

### How it works

1. **Startup**: Rust binary (`main.rs`) resolves `bundle-app/` from `Contents/Resources/`, spawns `node app/dist/index.js` with production env vars.
2. **Server**: Express starts on `127.0.0.1:3100` with `SERVE_UI=true`, serving the React UI from `ui-dist/`.
3. **Database**: Embedded PostgreSQL initializes in `~/.paperclip/instances/default/db` on first run. Migrations auto-apply.
4. **Window**: Tauri webview loads `http://localhost:3100` once the server is ready (TCP port probe, up to 90s timeout).
5. **Shutdown**: On `Cmd+Q`, Rust sends `SIGTERM` to the Node process for graceful embedded PostgreSQL shutdown, with a 10s hard-kill fallback.

### Key env vars stripped at spawn

The Rust binary removes Claude Code session env vars (`CLAUDECODE`, `CLAUDE_CODE_SSE_PORT`, `CLAUDE_CODE_SESSION`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_TASK_ID`, `CLAUDE_CODE_AGENT_ID`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) so that agents spawned by the Paperclip server are not blocked by nested-session detection.

### Tauri file structure

```
src-tauri/
  Cargo.toml                 Rust dependencies (tauri 2, libc, serde)
  build.rs                   Tauri build script
  tauri.conf.json            Tauri config (window, CSP, bundle resources, icons)
  src/
    main.rs                  App entry: resolve bundle, spawn server, manage lifecycle
    lib.rs                   (minimal)
  capabilities/
    default.json             Tauri v2 permissions (core:default)
  icons/                     Generated app icons (all sizes, icns, ico, png)
  bundle-app/                (gitignored) Staging directory built by prepare script
```

### Build commands

```sh
# Full build: prepare bundle + compile Tauri + create .app
pnpm tauri:build

# Dev mode: prepare bundle + run Tauri in dev
pnpm tauri:dev

# Regenerate icons from a source PNG
pnpm tauri icon ./app-icon.png

# Only prepare the bundle (no Tauri compile)
pnpm build:tauri
```

### Bundle preparation (`scripts/prepare-tauri-bundle.sh`)

This script creates the self-contained `src-tauri/bundle-app/` directory:

1. Downloads Node.js binary for macOS (arm64 or x64, auto-detected)
2. Runs `pnpm build` (compiles all workspace packages, UI, server, CLI)
3. Runs `pnpm --filter @paperclipai/server deploy` to get production-only node_modules
4. Copies built UI into `app/ui-dist/`
5. Patches workspace package.json `exports` fields: `./src/*.ts` -> `./dist/*.js` (eliminates tsx loader requirement)
6. Ensures DB migrations are included
7. Cleans unnecessary files (`.d.ts`, `.js.map`, tests, changelogs)

### Workspace package exports patching

In the monorepo, workspace packages (`@paperclipai/shared`, `@paperclipai/db`, etc.) use `"exports": { ".": "./src/index.ts" }` for dev (with tsx loader). The bundle script patches these to `"exports": { ".": "./dist/index.js" }` so the server runs with plain Node.js -- no tsx loader needed in production.

### Data persistence

All runtime data lives outside the `.app` bundle in `~/.paperclip/`:

```
~/.paperclip/
  instances/default/
    db/                      Embedded PostgreSQL data directory
    config.json              Instance configuration
    data/storage/            File storage (attachments, etc.)
```

### Build output locations

- `.app` bundle: `src-tauri/target/release/bundle/macos/Paperclip.app`
- `.dmg` installer: `src-tauri/target/release/bundle/dmg/Paperclip_0.1.0_aarch64.dmg`

### Build prerequisites (dev machine only)

- Rust toolchain (`rustup`): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- Node.js >= 20 and pnpm (for building the project)
- Xcode Command Line Tools (for macOS compilation)

The resulting `.app`/`.dmg` has zero external dependencies for end users.

### Modifying the Tauri app

- **Change app behavior/env vars**: edit `src-tauri/src/main.rs`
- **Change window size/title/CSP**: edit `src-tauri/tauri.conf.json`
- **Change app icon**: replace `app-icon.png` at project root, run `pnpm tauri icon ./app-icon.png`
- **Change bundled Node.js version**: edit `NODE_VERSION` in `scripts/prepare-tauri-bundle.sh`
- **Add Tauri plugins/features**: update `src-tauri/Cargo.toml` dependencies and `capabilities/default.json`

### Deployment modes summary

| Mode | Command | External deps | Use case |
|------|---------|---------------|----------|
| **Tauri .app** | `pnpm tauri:build` | None | Desktop app, self-contained |
| **Docker** | `docker compose up` | Docker | Server deployment |
| **Dev** | `pnpm dev` | Node.js, pnpm | Local development |
| **CLI** | `npx paperclipai onboard` | Node.js | Quick start |
