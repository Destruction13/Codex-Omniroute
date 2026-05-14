<!--
  Codex OmniRoute — README
  Source files of truth for the technical contract:
    - codex-omniroute-windows-spec.md  (normative spec for re-implementers)
    - GUIDE.md                          (day-to-day operator handbook)
  This file is the public landing page. Keep it scannable.
-->

<div align="center">

<!-- Hero banner (SVG generated on-the-fly by capsule-render.vercel.app) -->
<a href="#-quick-start">
  <img
    src="https://capsule-render.vercel.app/api?type=waving&color=gradient&customColorList=12,20,24&height=220&section=header&text=Codex%20OmniRoute&fontColor=ffffff&fontSize=64&fontAlignY=38&desc=Microsoft%20Store%20Codex%20%C3%97%20OmniRoute%20%E2%80%94%20zero%20quota,%20zero%20surprises&descAlignY=62&descSize=18&animation=fadeIn"
    alt="Codex OmniRoute"
    width="100%"
  />
</a>

<!-- Animated tagline -->
<a href="#-architecture">
  <img
    src="https://readme-typing-svg.demolab.com?font=Fira+Code&size=22&duration=2800&pause=900&color=8B5CF6&center=true&vCenter=true&width=720&lines=Keep+the+official+Codex+app+intact;Reroute+only+main+reasoning+through+OmniRoute;Spend+zero+account+quota;Voice+%2B+Compact+%2B+MCP+%2B+plugins+still+work"
    alt="Codex OmniRoute tagline"
  />
</a>

<br />

<!-- Status badges -->
<p>
  <img src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Windows 10/11" />
  <img src="https://img.shields.io/badge/node-%E2%89%A518.18-339933?style=for-the-badge&logo=node.js&logoColor=white" alt="Node.js >= 18.18" />
  <img src="https://img.shields.io/badge/codex-Microsoft%20Store-2EA44F?style=for-the-badge" alt="Codex from Microsoft Store" />
  <img src="https://img.shields.io/badge/setup-1%20double--click-8B5CF6?style=for-the-badge" alt="Setup: 1 double-click" />
  <img src="https://img.shields.io/badge/runtime%20deps-zero-E11D48?style=for-the-badge" alt="Zero runtime deps" />
</p>

<!-- Call-to-action buttons -->
<p>
  <a href="https://github.com/Destruction13/Codex-Omniroute/issues/new?title=OmniRoute+access+request&body=Hi%2C+I%27d+like+access+to+OmniRoute.+My+use+case%3A+">
    <img src="https://img.shields.io/badge/%F0%9F%94%91_Get_OmniRoute_Access-Open_Issue-blueviolet?style=for-the-badge" alt="Get OmniRoute access" />
  </a>
  <a href="#-quick-start">
    <img src="https://img.shields.io/badge/%E2%9A%A1_Quick_Start-Read-FB923C?style=for-the-badge" alt="Quick start" />
  </a>
  <a href="#-architecture">
    <img src="https://img.shields.io/badge/%F0%9F%8F%97_Architecture-Read-10B981?style=for-the-badge" alt="Architecture" />
  </a>
  <a href="https://github.com/Destruction13/Codex-Omniroute/issues">
    <img src="https://img.shields.io/badge/%F0%9F%90%9B_Report_a_Bug-Issues-EF4444?style=for-the-badge" alt="Report a bug" />
  </a>
</p>

</div>

---

## What is this

Codex OmniRoute is a **thin reasoning rerouter** around the unmodified Microsoft Store Codex desktop app. It runs the **same official binary** you'd launch from the Start Menu, but a managed block in your normal `~/.codex/config.toml` points its main reasoning calls at a local OpenAI-compatible bridge that forwards them to your OmniRoute endpoint instead of the OpenAI account behind your Codex login.

What you get out of it:

- **Codex stays Codex.** Voice Dictation, Compact, Skills, MCP servers, plugins, and future Store updates keep working. The Store package is never modified.
- **Zero account quota spent.** All reasoning calls leave through your OmniRoute key.
- **Both modes coexist.** Switch between OmniRoute mode and vanilla mode with a different `.bat` — no reinstall, no profile reset.

> [!IMPORTANT]
> This is **not** a Codex clone or a Codex replacement. It cannot work without the official Microsoft Store Codex app installed and signed in.

---

## ✨ Highlights

<table>
<tr>
<td align="center" width="33%">
<h3>🎯 Targeted</h3>
<p>Only <code>/v1/responses</code> and <code>/v1/chat/completions</code> are rerouted. Compact, dictation, models list, and everything else still hits the official upstream.</p>
</td>
<td align="center" width="33%">
<h3>🔀 Reversible</h3>
<p>OmniRoute mode adds a clearly-marked block to your real <code>~/.codex/config.toml</code> (with a backup). <code>-Restore</code> or launching <code>Start-Codex-Official.ps1</code> reverts it byte-for-byte. Codex still sees your real Windows profile, so file dialogs, <code>git</code>, and projects all work normally.</p>
</td>
<td align="center" width="33%">
<h3>⚡ One-click setup</h3>
<p><code>Setup.bat</code> verifies prerequisites, asks for your <code>base_url</code> + <code>api_key</code>, writes the gitignored config, runs a smoke test. Idempotent — safe to re-run.</p>
</td>
</tr>
<tr>
<td align="center">
<h3>🛡 Native behavior</h3>
<p>Codex is activated via the AppX broker (same path the Start Menu takes), so <code>apply_patch.bat</code>, <code>rg</code>, MCP servers, file dialogs, and <code>git</code> all keep working out of the box. The managed block enables <code>experimental_use_freeform_apply_patch</code> as an extra safety net.</p>
</td>
<td align="center">
<h3>🔍 Verifiable</h3>
<p><code>verify-codex-omniroute.ps1</code> checks bridge health, managed-block presence, backup existence, and the <code>-Restore</code> round-trip. Optional <code>-Live</code> exercises real OmniRoute.</p>
</td>
<td align="center">
<h3>📦 Zero deps</h3>
<p>The bridge is pure Node 18+ stdlib. No <code>npm install</code> required for normal operation. <code>zstd</code> support is opt-in via dynamic import only if you actually receive zstd-encoded bodies.</p>
</td>
</tr>
</table>

---

## ⚡ Quick start

> [!TIP]
> Total time: about **7 minutes**. Five double-clicks plus one Microsoft Store search and one message to the maintainer.

<table>
<tr><td><h3>1️⃣ &nbsp; Install Codex from the Microsoft Store</h3></td></tr>
<tr><td>

Search for <b>OpenAI Codex</b> in Microsoft Store, install it, sign in once, open the app, then close it. This populates `auth.json` and `models_cache.json` under your user profile so the wizard has something to seed from later.

<a href="https://apps.microsoft.com/search?query=openai+codex"><img src="https://img.shields.io/badge/Open_Microsoft_Store-Search_OpenAI_Codex-0078D6?style=for-the-badge&logo=microsoftstore&logoColor=white" alt="Open Microsoft Store" /></a>

</td></tr>

<tr><td><h3>2️⃣ &nbsp; Install Node.js (LTS)</h3></td></tr>
<tr><td>

Run the LTS installer with default options. The bridge needs Node `>= 18.18`.

<a href="https://nodejs.org/"><img src="https://img.shields.io/badge/Download_Node.js-LTS-339933?style=for-the-badge&logo=node.js&logoColor=white" alt="Download Node.js LTS" /></a>

</td></tr>

<tr><td><h3>3️⃣ &nbsp; Get the repo onto your machine</h3></td></tr>
<tr><td>

**No git required:** click the green **Code** button on this page → **Download ZIP**, then unzip somewhere stable like `C:\Tools\Codex-Omniroute\`.

**With git:**
```powershell
git clone https://github.com/Destruction13/Codex-Omniroute.git
```

</td></tr>

<tr><td><h3>4️⃣ &nbsp; Get OmniRoute access from the maintainer</h3></td></tr>
<tr><td>

You need two values: a `base_url` and an `api_key`. They are issued out-of-band by the repo maintainer — see [Where to get OmniRoute access](#-where-to-get-omniroute-access) below.

<a href="https://github.com/Destruction13/Codex-Omniroute/issues/new?title=OmniRoute+access+request&body=Hi%2C+I%27d+like+access+to+OmniRoute.+My+use+case%3A+"><img src="https://img.shields.io/badge/Request_Access-Open_Issue-8B5CF6?style=for-the-badge&logo=github&logoColor=white" alt="Request OmniRoute access" /></a>

</td></tr>

<tr><td><h3>5️⃣ &nbsp; Run the setup wizard</h3></td></tr>
<tr><td>

In the unzipped repo folder, **double-click `Setup.bat`**. The wizard:

1. Verifies that Codex (Microsoft Store) and Node.js (`>= 18.18`) are installed. If anything is missing, it prints a direct download link.
2. Asks for your OmniRoute `base_url` (echoes to the terminal) and `api_key` (input is hidden). **Those are the only two questions.**
3. Writes `omniroute-provider.json` (already in `.gitignore`) with sane defaults for everything else (`model_prefix = "cx/"`, `default_model = "gpt-5.4"`, `gpt55_pin.enabled = false`). If you ever need to tweak those advanced fields, edit the JSON file by hand.
4. Runs `verify-codex-omniroute.ps1 -NoCodex` and prints a `PASS`/`FAIL` table.

If the table ends with `OK Verifier passed`, you're done. Even if the verifier reports `WARN`/`FAIL`, the config has been written and you can proceed to `Start-Codex-OmniRoute.bat`.

</td></tr>

<tr><td><h3>6️⃣ &nbsp; Use Codex with OmniRoute</h3></td></tr>
<tr><td>

| Action | What to do |
|---|---|
| **Codex with OmniRoute reasoning** | Double-click `Start-Codex-OmniRoute.bat` |
| **Vanilla Codex (your normal account)** | Double-click `Start-Codex-Official.bat` |
| **Watch traffic** | `Get-Content .\bridge.log -Tail 50 -Wait` in PowerShell |

Both modes can be invoked at any time. OmniRoute mode appends a clearly-marked block to your `~/.codex/config.toml` (with a backup); `Start-Codex-Official.ps1` auto-restores the original before launching, and `Start-Codex-OmniRoute.ps1 -Restore` reverts without launching anything.

</td></tr>
</table>

> [!NOTE]
> If something goes wrong on first run, the [GUIDE.md "When something goes wrong"](GUIDE.md#when-something-goes-wrong) table covers the common failure modes (`Get-AppxPackage returned nothing`, `models_cache_missing`, `omniroute_not_configured`, etc.) with one-line fixes.

---

## 🔑 Where to get OmniRoute access

This repo is the **client side** of OmniRoute. The OmniRoute server itself — the actual reasoning provider that the bridge talks to — is operated by the repo maintainer. Access is issued on request.

To get a working `base_url` + `api_key`:

<table>
<tr>
<td align="center" width="50%">
<h3>📨 Open an issue</h3>
<p>Public, easy to track, works for everyone.</p>
<a href="https://github.com/Destruction13/Codex-Omniroute/issues/new?title=OmniRoute+access+request&body=Hi%2C+I%27d+like+access+to+OmniRoute.+My+use+case%3A+"><img src="https://img.shields.io/badge/Request_Access-blueviolet?style=for-the-badge&logo=github&logoColor=white" alt="Request access" /></a>
</td>
<td align="center" width="50%">
<h3>👤 Contact the maintainer</h3>
<p>For private use cases or follow-up questions.</p>
<a href="https://github.com/Destruction13"><img src="https://img.shields.io/badge/@Destruction13-GitHub-181717?style=for-the-badge&logo=github&logoColor=white" alt="Maintainer profile" /></a>
</td>
</tr>
</table>

You'll receive two values:

1. **`base_url`** — looks like `http://127.0.0.1:20128/v1` (if you'll tunnel via SSH; instructions delivered with credentials) or a direct `https://...` endpoint.
2. **`api_key`** — an opaque token. **Treat it like a password.** Don't paste it into chats. Don't commit it. Don't email it in plaintext.

Drop both into `Setup.bat` when prompted. They land in `omniroute-provider.json`, which `.gitignore` excludes.

> [!WARNING]
> Never commit `omniroute-provider.json`, `.env`, or `auth.json`. The `.gitignore` already excludes them, but check `git status` before pushing if you've been editing config by hand.

---

## 🏗 Architecture

```mermaid
flowchart LR
    user([👤 You])
    codex[🖥️ Codex Desktop<br/>Microsoft Store binary,<br/>unmodified]
    bridge[🔀 Local Bridge<br/>127.0.0.1<br/>codex-openai-omniroute-bridge.mjs]
    omni[☁️ OmniRoute<br/>your endpoint]
    official[🏛 chatgpt.com<br/>backend-api/codex]
    cache[(📁 ~/.codex/<br/>models_cache.json)]

    user -->|launches| codex
    codex -->|/v1/responses<br/>/v1/chat/completions| bridge
    codex -->|/v1/responses/compact| bridge
    codex -->|/v1/audio/transcriptions| bridge
    codex -->|/v1/models| bridge

    bridge -->|main reasoning| omni
    bridge -->|compact + dictation<br/>+ everything else| official
    bridge -.->|served from disk| cache

    classDef purple fill:#8B5CF6,stroke:#6D28D9,color:#fff,stroke-width:2px
    classDef blue   fill:#3B82F6,stroke:#1D4ED8,color:#fff,stroke-width:2px
    classDef green  fill:#10B981,stroke:#059669,color:#fff,stroke-width:2px
    classDef gray   fill:#374151,stroke:#1F2937,color:#fff,stroke-width:2px

    class bridge purple
    class omni blue
    class official green
    class codex,user,cache gray
```

The launcher (`Start-Codex-OmniRoute.ps1`) backs up your existing `~/.codex/config.toml` to `config.toml.codex-omniroute-backup` and inserts a clearly-marked managed block into the real config:

```toml
# >>> codex-omniroute-managed (auto-generated; do not edit by hand)
model_provider = "omniroute_bridge"
model = "gpt-5.4"
profile = "omniroute_managed"
experimental_use_freeform_apply_patch = true

[model_providers.omniroute_bridge]
base_url = "http://127.0.0.1:<bridge_port>/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false

[profiles.omniroute_managed]
model_provider = "omniroute_bridge"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"
# <<< codex-omniroute-managed
```

Then it launches Codex Desktop via the AppX broker (`IApplicationActivationManager`), the same way the Start Menu does, so the package keeps its identity, can call into `WindowsApps\...\app\apply_patch.bat` without Access Denied, and your normal Windows profile (`%USERPROFILE%`, `%APPDATA%`, `~/.gitconfig`, SSH keys, Documents, Desktop, projects) is fully visible. Codex sends its main reasoning to `127.0.0.1:<bridge_port>`, and the bridge forwards to OmniRoute. Everything else (Compact, Dictation, Skills, MCP, plugins, account telemetry) reaches the official Codex backend unchanged.

When you want vanilla Codex back, run `Start-Codex-OmniRoute.ps1 -Restore` or just launch `Start-Codex-Official.ps1` — the official launcher auto-restores the backup and stops the bridge before activating Codex.

<details>
<summary><b>📋 Bridge route surface (click to expand)</b></summary>

| Route | Method | Where it goes | Notes |
|---|---|---|---|
| `/healthz` | GET | local | Status JSON: port, pid, omniroute config presence, official auth presence |
| `/v1/models` | GET | `~/.codex/models_cache.json` | **Never** fetched from OmniRoute |
| `/v1/responses` | POST | OmniRoute | Main reasoning. Model normalized (`gpt-5.4` → `cx/gpt-5.4`), `store=false`, optional GPT-5.5 connection-ID pin |
| `/v1/chat/completions` | POST | OmniRoute | Same normalization |
| `/v1/responses/compact` | POST | official upstream | Compact behavior; uses inbound auth or `auth.json` fallback |
| `/v1/audio/transcriptions` | POST | official upstream | Voice Dictation; `x-codex-base64: 1` envelopes decoded locally |
| `/transcribe` | POST | official upstream `/audio/transcriptions` | Same base64 handling |
| `/v1/images/generations` | GET/POST | official upstream | Optional parity |
| anything else | * | official upstream | Catchall preserves account/MCP/skills/plugins backend calls |

</details>

<details>
<summary><b>🔬 Architecture truth & core invariants (click to expand)</b></summary>

### What changes vs vanilla Codex

| Concern | Behavior |
|---|---|
| Codex UI / Voice Dictation / Skills / MCP / plugins / updates | **Official Microsoft Store app, untouched.** Launched via the AppX broker (`IApplicationActivationManager`), exactly like the Start Menu does. |
| Desktop identity / window separation | **None.** Codex keeps its normal package identity and runs against your normal Windows profile. |
| File dialogs, `git`, SSH, projects | **Your real `%USERPROFILE%`.** No env-var overrides, no isolated `HOME`. |
| `~/.codex/config.toml` | **A clearly-marked managed block is appended** (see Architecture). The original file is backed up to `config.toml.codex-omniroute-backup` and restored when you switch back. Any existing `[mcp_servers.*]`, `[plugins.*]`, etc. stay intact. |
| `~/.codex/auth.json` | **Temporarily replaced with a managed API-key sentinel** (`OPENAI_API_KEY = "sk-omniroute-managed"`). This flips Codex Desktop into API-key auth mode so main reasoning actually flows through the bridge instead of going to chatgpt.com directly via the ChatGPT OAuth session. Your real `auth.json` is backed up to `auth.json.codex-omniroute-backup` and restored byte-for-byte by `-Restore` / Official mode; the bridge still uses it (via `CODEX_OFFICIAL_AUTH_PATH`) for compact + dictation passthrough. |
| Main reasoning (`/v1/responses`, `/v1/chat/completions`) | **Bridge → OmniRoute** with model normalization, `store=false`, optional GPT-5.5 connection-ID pin. |
| Compact (`/v1/responses/compact`) | **Bridge → official upstream**, using the backed-up real `auth.json` as the bearer (the inbound sentinel is stripped). |
| Dictation (`/v1/audio/transcriptions`, `/transcribe`) | **Bridge → official upstream**, including base64 multipart envelopes tagged with `x-codex-base64: 1`. |
| Models list (`/v1/models`) | **Served from `~/.codex/models_cache.json`** — never fetched from OmniRoute. |
| MCP definitions, marketplaces, plugins | **Untouched.** Codex reads them from its normal config; the managed block only adds the `omniroute_bridge` provider/profile + four top-level keys. |
| `git`, `node`, `npx`, etc. | **User's real binaries.** No git shim, no `PATH` override. |
| `apply_patch.bat` | **Codex's real one in the AppX package.** Works because Codex is activated as a package, not via direct `CreateProcess` against `WindowsApps\...\Codex.exe`. |

### Core invariants (each enforced by the launchers and asserted by the verifier)

1. The Codex executable launched is the unmodified package resolved from `Get-AppxPackage OpenAI.Codex`; no install path is hardcoded.
2. Codex is activated via `IApplicationActivationManager.ActivateApplication` (the AppX broker), exactly like the Start Menu does — not via `Start-Process` against `WindowsApps\...\Codex.exe`. This preserves package identity and prevents Access-Denied on package-internal tools like `apply_patch.bat`.
3. **Official mode** (`Start-Codex-Official.ps1`) inherits the user's environment unchanged. It sets *no* `CODEX_*` / `OMNIROUTE_*` env vars and starts *no* helper processes. Before activating Codex it auto-restores any backups at `~/.codex/config.toml.codex-omniroute-backup` and `~/.codex/auth.json.codex-omniroute-backup`, and stops a running managed bridge.
4. **OmniRoute mode** (`Start-Codex-OmniRoute.ps1`) inherits the user's environment unchanged. The only side-effects are: (a) a clearly-marked block appended to `~/.codex/config.toml`, (b) a `config.toml.codex-omniroute-backup` next to it, (c) `~/.codex/auth.json` replaced with a managed API-key sentinel (`OPENAI_API_KEY = "sk-omniroute-managed"`, `tokens = null`) so Desktop is in API-key auth mode and main reasoning hits the bridge, (d) an `auth.json.codex-omniroute-backup` next to it preserving the user's real OAuth session, (e) a managed `node` bridge process tracked by `bridge.pid` next to the launcher.
5. The managed block is delimited by `# >>> codex-omniroute-managed` / `# <<< codex-omniroute-managed` markers. Re-running the launcher replaces the block in place; conflicting top-level keys (`model_provider`, `model`, `profile`, `model_reasoning_effort`) outside any section header are stripped to prevent dual-config drift. The managed `auth.json` carries an `_codex_omniroute.managed = true` marker plus the sentinel `OPENAI_API_KEY` for the same kind of detection.
6. `Start-Codex-OmniRoute.ps1 -Restore` (and `Start-Codex-Official.ps1`) restore the `config.toml` and `auth.json` backups byte-for-byte (or delete the managed files outright when no original existed), delete the backup files, and stop the bridge.
7. The bridge binds to `127.0.0.1` only.
8. The managed `omniroute_bridge` provider pins `requires_openai_auth = true`, `supports_websockets = false`, `wire_api = "responses"`.
9. Main reasoning goes to OmniRoute; compact + transcription go to the official upstream.
10. `/v1/models` is served from the user's `~/.codex/models_cache.json`, not OmniRoute.
11. The bridge decodes gzip / deflate / brotli / (zstd if a decoder is installed) request bodies and `x-codex-base64: 1` multipart envelopes.
12. Model identifiers like `gpt-5.4` are normalized to `cx/gpt-5.4` (prefix is configurable) before forwarding.
13. No connection IDs, account IDs, or API keys are hardcoded; everything sensitive comes from env, `omniroute-provider.json` (gitignored), or an OpenCode-style provider config.
14. `verify-codex-omniroute.ps1` exercises all of the above, including the `-Restore` round-trip, without leaving the user's config in a modified state.

</details>

---

## ✅ Verify

After setup, you can re-run the verifier any time:

```powershell
.\verify-codex-omniroute.ps1
```

It runs `Start-Codex-OmniRoute.ps1 -NoCodex` (bridge only, no Codex GUI), checks the small set of invariants above (managed block present, bridge `/healthz` responding, backup file exists, official launcher resolves package cleanly, `-Restore` round-trip works), prints a `PASS` / `WARN` / `FAIL` table, and leaves the user's config in its original state. Optional `-Live` flag exercises real OmniRoute `/v1/responses`:

```powershell
.\verify-codex-omniroute.ps1 -Live
```

> [!NOTE]
> The `bridge-models` row may show `WARN` on a fresh install — it goes `PASS` after Codex Desktop has been opened at least once so it can populate `~/.codex/models_cache.json` from `chatgpt.com`.

---

## 🛠 Day-to-day usage

For deeper operational notes — switching modes, resetting the runtime, tunneling OmniRoute, GPT-5.5 pinning, MCP debugging, choosing which account to seed, troubleshooting `apply_patch` failures — see <a href="GUIDE.md"><b>GUIDE.md</b></a>.

For the normative implementation contract (what every component must do, what it must never do, how to re-implement it from scratch), see <a href="codex-omniroute-windows-spec.md"><b>codex-omniroute-windows-spec.md</b></a>.

---

## 🔬 Advanced

<details>
<summary><b>📂 File plan</b></summary>

```
codex-omniroute/
├── README.md                            # this file (public landing page)
├── GUIDE.md                             # day-to-day operator handbook
├── codex-omniroute-windows-spec.md      # normative contract for re-implementers
├── Setup.bat                            # ★ first-time wizard (double-click this)
├── Setup.ps1                            # the wizard logic
├── Start-Codex-Official.ps1             # clean baseline launcher (auto-restores config)
├── Start-Codex-OmniRoute.ps1            # writes managed block + starts bridge + AppX-activates Codex
├── Start-Codex-Official.bat             # convenience wrapper (double-clickable)
├── Start-Codex-OmniRoute.bat            # convenience wrapper (double-clickable)
├── codex-openai-omniroute-bridge.mjs    # local OpenAI-compatible bridge
├── verify-codex-omniroute.ps1           # invariant checker + optional live smoke
├── omniroute-provider.example.json      # template; Setup.bat creates omniroute-provider.json from this
├── .env.example                         # env vars the bridge understands (alternative to JSON)
├── .gitignore                           # excludes secrets, logs, pid, legacy isolated-home dirs
├── package.json                         # node engines + scripts (no runtime deps)
├── mock-transcribe-upstream.mjs         # offline test target for /transcribe
└── tools/
    ├── mcp_probe.mjs                    # per-server JSON-RPC initialize probe (optional diagnostics)
    └── mcp-stdio-shield.mjs             # optional stdio filter for misbehaving MCP children
```

</details>

<details>
<summary><b>🧰 Manual setup (advanced — skip if you ran <code>Setup.bat</code>)</b></summary>

This section is for users who want to bypass the wizard and configure the provider by hand.

1. Install the official **Codex** app from the Microsoft Store. Sign in normally.
2. `git clone` this repo into your project workspace.
3. Configure the OmniRoute provider — pick one:

   **Environment variables (highest priority):**
   ```powershell
   $env:OMNIROUTE_BASE_URL = "http://127.0.0.1:20128/v1"   # or your remote
   $env:OMNIROUTE_API_KEY  = "<your-omniroute-key>"
   ```

   **Local provider JSON:**
   ```powershell
   Copy-Item .\omniroute-provider.example.json .\omniroute-provider.json
   # edit omniroute-provider.json (it's gitignored)
   ```

   **OpenCode-style** `~/.config/opencode/auth.json` with a provider entry named `cloud_omni`, `miracloud`, or `omniroute`.

4. Optional: if you tunnel OmniRoute, run the SSH tunnel separately:
   ```powershell
   ssh -L 20128:127.0.0.1:<remote_port> -L 1455:127.0.0.1:1455 <your-user>@<your-host>
   ```
   The repo never includes the tunnel command or its credentials.

The launchers work on both Windows PowerShell 5.1 (the default `powershell.exe`) and PowerShell 7+ (`pwsh.exe`). PowerShell 7+ is **recommended but not required** — the `.bat` shims auto-prefer `pwsh.exe` when it's on `PATH` and fall back to `powershell.exe` otherwise. `Setup.bat` will offer to install PowerShell 7+ via `winget` if it's missing, and continues with the built-in PowerShell if you decline.

</details>

<details>
<summary><b>🔐 Things that must remain parameterized or redacted</b></summary>

| Value | Source of truth | Notes |
|---|---|---|
| OmniRoute API key | `OMNIROUTE_API_KEY` env or `api_key` in `omniroute-provider.json` | Gitignored |
| OmniRoute base URL | Same as above | Gitignored if private |
| GPT-5.5 connection ID | `OMNIROUTE_55_CONNECTION_ID` or `gpt55_pin.connection_id` | Opt-in only |
| Codex `auth.json` | `%USERPROFILE%\.codex\auth.json` | Gitignored. Read by the bridge for compact/dictation auth fallback. |
| `models_cache.json` / `installation_id` | `%USERPROFILE%\.codex\` | Maintained by Codex itself; the bridge serves `models_cache.json` to `GET /v1/models`. |
| MCP server definitions | Inherited from user's official `config.toml` | Whatever the user has |
| SSH tunnel host / user / password | Nowhere in this repo | Rotate if leaked |

The bridge **never** logs `Authorization` headers, API keys, tokens, account IDs, connection IDs, cookies, or `auth.json` contents.

</details>

<details>
<summary><b>🪟 What still requires a real Windows machine or real credentials</b></summary>

The repo is implementable on Linux but **not fully exercisable** without:

- A Windows machine with the **Microsoft Store Codex app** installed and signed in.
- A reachable **OmniRoute** endpoint and API key for live `/v1/responses` smoke.
- A **real `auth.json`** under `%USERPROFILE%\.codex\` for the `auth.json` / `account_id` fallback paths and for live Compact / Dictation smoke.

Without these, `Start-Codex-Official.ps1`, `Start-Codex-OmniRoute.ps1`, and `verify-codex-omniroute.ps1` surface clear errors (`Get-AppxPackage` returning nothing, `models_cache.json` missing, `omniroute_not_configured`).

</details>

---

## 📜 License & contact

<table>
<tr>
<td width="50%">
<h3>License</h3>
<p>This repository is private/unpublished — no license is granted for redistribution. If you obtained access, use it for the agreed-upon scope.</p>
</td>
<td width="50%">
<h3>Contact</h3>
<p>Questions, access requests, bug reports → <a href="https://github.com/Destruction13/Codex-Omniroute/issues">open an issue</a> or contact <a href="https://github.com/Destruction13"><b>@Destruction13</b></a>.</p>
</td>
</tr>
</table>

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&customColorList=24,20,12&height=120&section=footer" alt="" width="100%" />

<sub>If you're reading this and Codex still feels broken, run <code>.\verify-codex-omniroute.ps1</code> — the first <code>FAIL</code> row tells you what's wrong.</sub>

</div>
