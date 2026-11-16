<div align="center">

# OpenCode Custom Provider

**In-App Custom Provider Manager, Built-in Model Effort Booster (`xhigh` / `max` / `ultra`), and Native GUI Installer for OpenCode Desktop & CLI.**

![Version](https://img.shields.io/badge/Version-1.3.0-2F81F7?style=for-the-badge)
![OpenCode](https://img.shields.io/badge/OpenCode-v1.x%20%7C%20v2.x-238636?style=for-the-badge)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-6E7681?style=for-the-badge)
![Protocols](https://img.shields.io/badge/Protocols-OpenAI%20%7C%20Responses%20%7C%20Anthropic%20%7C%20Gemini-8957E5?style=for-the-badge)
![Zero Deps](https://img.shields.io/badge/Dependencies-Zero%20Runtime%20Deps-1F6FEB?style=for-the-badge)

[Features](#-features) · [Model Booster](#-built-in--connected-model-booster) · [Installation](#-installation) · [Protocols](#-supported-protocols) · [CLI & Automation](#-cli--automation-options) · [Troubleshooting](#-troubleshooting)

</div>

---

## Overview

**OpenCode Custom Provider** restores and expands visual provider management inside **OpenCode Desktop (`v2.2+`)** and keeps everything cleanly synchronized in `opencode.jsonc` across Desktop, TUI, and CLI — while also bundling a **Dark-Mode Windows GUI Installer & Direct Configurator** (`installer-gui.ps1`) so even older OpenCode builds (`v1.x` / `v2.0` / `v2.1`) can configure providers, context/output limits, and `xhigh` / `max` / `ultra` reasoning tiers without manual JSON editing.

---

## ✨ Features

### 🖥️ OpenCode Desktop Plugin (`Settings → Custom Providers` & `/custom-provider`)
- **Two-Tab Master-Detail Editor** — Clean split between **`1. Connection & Fetch`** and **`2. Models & Efforts`**, automatically opening on the Models tab when editing existing providers.
- **Auto-Discover Models (`Test & Fetch Models`)** — Queries `/models` with automatic `/v1/models` fallback, smart HTML landing-page detection, and suggested normalized Base URLs.
- **Per-Model Context & Output Limits** — Quick presets for Context (`128K`, `200K`, `400K`, `1M`, `Auto`) and Output (`16K`, `32K`, `64K`, `128K`, `Auto`) or custom numbers, plus **`Copy to All Models`**.
- **Per-Model API Compatibility** — Mix different protocols under a single provider/proxy (for example, Anthropic Messages models alongside OpenAI Chat models) via per-model `package` mapping.
- **JSON / JSONC & Legacy V1 Import** — Paste provider JSON/JSONC snippets or import Desktop configs directly into modern **OpenCode V2 (`providers`)** format.
- **Instant Soft Reload & Windows File Safety** — Automatically triggers OpenCode catalog reload (`POST /api/location/reload`) on save/delete/import and uses serialized atomic writes with retry fallback for Windows file-watcher locks.

### ⚡ Built-in & Connected Model Booster (`Boost Any Model`)
Unlock reasoning effort tiers beyond `high` and customize Context/Output limits on **non-custom / built-in / connected** models (`opencode`, `openai`, `anthropic`, `google`, `agentrouter`, or any manual `provider/model`) without touching your API keys or provider integrations:
- Full effort tiers: **`none` · `minimal` · `low` · `medium` · `high` · `xhigh` · `max` · `ultra`**
- Configurable **`ultra` Target** (`Auto Default`, `max`, `xhigh`, or `ultra`)
- Search & filter the live catalog, boost individual models or batch-boost an entire provider (`batchBoostModels`)
- Writes clean **partial overrides** into `opencode.jsonc` (`providers.<id>.models.<model>`) so built-in endpoints, auth, tools (`tools: true`), and multimodal capabilities (`text`, `image`, `video`, `audio`, `pdf`) stay intact
- One-click **`Reset to Default`** that removes the override cleanly without leaving empty stubs behind

### 🛠️ Universal Windows GUI Installer (`Install-Windows.bat`)
A self-contained **Dark-Mode WPF app** with zero external dependencies and two tabs:
1. **`1. Install Desktop Plugin (v2.2+)`** — Detects your OpenCode config directory and Desktop executable, installs or updates cleanly, unblocks extracted files, and offers one-click restart.
2. **`2. Direct Provider Setup (All Versions: v1.x / v2.x)`** — Load existing custom providers, fetch models, tweak limits/efforts/per-model compatibility, and write either **OpenCode V2 (`providers`)** or **Legacy V1 (`provider`)** directly into `opencode.jsonc`.

---

## 🔌 Supported Protocols

| Preset | OpenCode V2 Package | Typical Use Case |
| :--- | :--- | :--- |
| **OpenAI Compatible (Chat Completions)** | `@opencode/ai/providers/openai-compatible` | Custom proxies, Ollama, LM Studio, vLLM, gateways |
| **OpenAI Compatible (Responses API)** | `@opencode/ai/providers/openai-compatible/responses` | Reasoning / Responses API proxies |
| **Anthropic Compatible (Messages API)** | `@opencode/ai/providers/anthropic` | Claude proxies and Anthropic-format endpoints |
| **OpenAI Official Format** | `@opencode/ai/providers/openai` | Direct OpenAI-format endpoints |
| **Google Gemini Compatible** | `@opencode/ai/providers/google` | Gemini API & compatible gateways |

---

## 📦 Installation

### Windows (Recommended — GUI Installer)
1. If you downloaded a `.zip` archive, right-click it and select **Extract All...** first.
2. Double-click **`Install-Windows.bat`**.
3. In the installer window:
   - On **OpenCode `v2.2+`** (including `v2.3.0`): stay on tab **`1. Install Desktop Plugin (v2.2+)`** and click **Install / Update Plugin**.
   - On **older versions (`< 2.2.0`)**: switch to tab **`2. Direct Provider Setup`** to write providers directly to `opencode.jsonc`.
4. Completely quit **OpenCode Desktop** (**System Tray icon → Quit**) and reopen it, then go to **Settings → Custom Providers** or run `/custom-provider`.

> To uninstall on Windows, run **`Uninstall-Windows.bat`** (or use **Uninstall Plugin** inside the GUI).

### macOS & Linux
```bash
bash install.sh
```
- Uses a native dialog automatically on macOS (`osascript`) and Linux desktops (`zenity` / `kdialog`), or falls back cleanly to terminal mode.
- Installs to `$OPENCODE_CONFIG_DIR/plugins/custom-provider` (or `$XDG_CONFIG_HOME/opencode/plugins/custom-provider`, defaulting to `~/.config/opencode/plugins/custom-provider`).

---

## ⚙️ CLI & Automation Options

<details>
<summary><strong>Windows PowerShell / Batch Flags</strong></summary>

```powershell
# Launch GUI directly on the Direct Provider Setup tab
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\installer-gui.ps1 -InitialTab Setup

# Headless install + auto-restart OpenCode Desktop
.\install.ps1 -RestartOpenCode

# Custom config directory + quiet mode
.\Install-Windows.bat -ConfigDir "D:\custom\.config\opencode" -Quiet

# Headless uninstall
.\install.ps1 -Uninstall -Quiet
```

</details>

<details>
<summary><strong>macOS / Linux Bash Flags (`install.sh`)</strong></summary>

```bash
bash install.sh --cli                      # Force terminal mode (no GUI prompt)
bash install.sh --config-dir /custom/path  # Override OpenCode config directory
bash install.sh --uninstall                # Remove custom-provider plugin
bash install.sh --quiet                    # Minimal output (implies --cli)
bash install.sh --help                     # Show all options
```

</details>

---

## 📁 Package Structure

```text
opencode-custom-provider/
├── Install-Windows.bat       # Double-click GUI launcher (also forwards CLI flags to install.ps1)
├── Uninstall-Windows.bat     # GUI / CLI uninstaller launcher
├── installer-gui.ps1         # Dark-Mode WPF Installer & Direct V1/V2 Configurator
├── install.ps1               # Windows PowerShell CLI installer/uninstaller
├── install.sh                # macOS / Linux installer/uninstaller
├── README.md
└── plugin/                   # Copied to <config>/plugins/custom-provider/
    ├── package.json          # Plugin manifest (v1.3.0)
    ├── index.js              # Server entrypoint
    └── gui-experimental.cjs  # Desktop Settings UI, Command & IPC logic
```

<details>
<summary><strong>Example `opencode.jsonc` Output (Custom Provider + Partial Built-in Override)</strong></summary>

```jsonc
{
  "providers": {
    // 1. Custom Provider (full endpoint + models)
    "my-proxy": {
      "name": "My API Proxy",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "https://api.example.com/v1"
      },
      "models": {
        "claude-sonnet": {
          "name": "Claude Sonnet",
          "package": "@opencode/ai/providers/anthropic",
          "limit": { "context": 200000, "output": 32000 },
          "capabilities": {
            "reasoning": { "supported": true, "effort": ["low", "medium", "high", "xhigh", "max"] }
          },
          "variants": [{ "id": "ultra", "settings": { "reasoningEffort": "xhigh" } }]
        }
      }
    },

    // 2. Partial Built-in Model Boost (preserves built-in keys, tools & multimodal inputs)
    "opencode": {
      "models": {
        "hy4-flash-free": {
          "capabilities": {
            "reasoning": { "supported": true, "effort": ["low", "medium", "high", "xhigh", "max"] }
          },
          "variants": [{ "id": "ultra", "settings": { "reasoningEffort": "xhigh" } }]
        }
      }
    }
  }
}
```

</details>

---

## 🔧 Troubleshooting

- **Plugin tab doesn't appear or shows an older version after updating**
  Make sure **OpenCode Desktop** is completely closed — right-click its icon in the **System Tray** → **Quit** (not just closing the window) — then reopen it, or run with `-RestartOpenCode`.
- **Old plugin path cached in `opencode.jsonc`**
  Check if your `opencode.jsonc` has a stale path inside the `"plugin"` array pointing to an older copy of `custom-provider`, and remove it so OpenCode loads `<config>/plugins/custom-provider/`.
- **"Installer files not found next to this script"**
  Always **Extract All...** from the `.zip` before running `Install-Windows.bat`; Windows cannot run relative installer scripts directly from inside an unextracted compressed folder.
