# Repage SteamGrid

![Version](https://img.shields.io/github/v/release/Klastein/Repage-SteamGrid?label=version&color=438FCB&style=flat-square)
![Framework](https://img.shields.io/badge/Millennium-Steam%20Plugin-1b2838?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20Steam%20Deck-2a475e?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-49C695?style=flat-square)

**Repage SteamGrid** is a complete artwork studio built directly inside Steam via [Millennium](https://github.com/SteamClientHomebrew/Millennium) and powered by [SteamGridDB](https://www.steamgriddb.com). Rebuilt from *Easy SteamGrid*, it brings effortless customization for your entire Steam library — from single-click artwork swaps and bulk collection updates to local custom files, profile backups, and native controller navigation on Desktop, Big Picture, and Steam Deck.

---

## Why Repage SteamGrid?

- **Everything in one place:** Browse, preview, favorite, save, apply, or reset all 5 Steam artwork slots without leaving the Steam client or juggling external apps.
- **Opens right where you need it:** Context-aware entry points automatically open the matching tab for the element you clicked — no extra tab switching required.
- **Built for massive catalogs:** Designed to handle libraries with hundreds of games and thousands of community artworks smoothly, with low memory footprint and an optional **Performance Mode** for handhelds and low-spec PCs.
- **True multi-input parity:** Every feature — including filters, multi-select menus, library management, and theme color pickers — works seamlessly with Mouse, Keyboard, Touch, and Xbox / PlayStation / Steam Deck controllers.
- **Independent & safe:** Runs cleanly alongside the original Easy SteamGrid, isolates itself from third-party Steam themes, and keeps your API key and custom artwork per-slot safe.

---

## What You Can Do

### 🖼️ Complete Artwork Control
- **All 5 Steam Slots:** Customize vertical **Grids**, **Wide Grids**, **Heroes**, **Logos**, and **Icons** (for both Steam games and non-Steam shortcuts).
- **Live Current-Artwork Preview:** Inspect what is currently applied to any slot before replacing or resetting it.
- **Local Files:** Apply your own `.png`, `.jpg`, `.webp`, `.gif`, `.ico`, or `.webm` artwork from disk; local files stay pinned at the top of the slot for quick re-applying.
- **Save to Disk:** Right-click any image (or press `X` on a controller) to download it directly to your chosen folder or Downloads directory.
- **Official Steam Fallback:** Restore original Steam store assets at any time via **Set to Steam Assets** or **Reset**.

### ⚡ Smart Opening & Bulk Automation
- **Context-Aware Tab Selection:**
  - Double-click a game's library banner → opens on **Hero**.
  - Right-click a vertical library cover → opens on **Grid**.
  - Right-click a horizontal cover (Recent / Featured / Big Picture) → opens on **Wide Grid**.
  - Right-click a game in the left library sidebar → opens on **Icon**.
  - Press `Ctrl + Shift + P` (or `R2/RT + L3 + R3`) anywhere → toggles the editor on the current game.
- **Auto Replace & Collection Tools:** Replace all artwork for a single game in one click, or batch-replace / reset entire Steam Collections by artwork type while skipping games on your **Excluded APPIDs** list.
- **Wrong Match? Easy Fix:** Search by game name fallback or enter any numeric **SteamGridDB ID** directly in the toolbar.

### 🔍 Precision Discovery & Curation
- **Instant Client-Side Sorting & Filtering:** Sort by *Score*, *Newest*, *Author*, or *Resolution*, and filter by *NSFW*, *Humor*, *Epilepsy*, *Types* (Static / Animated), *Formats*, *Styles*, and *Dimensions*.
- **Artist Priority & Blocking:** Build ordered priority lists or exclude specific artists via tags or straight from any image's context menu.
- **Pinned Favorite Artworks:** Favorite your top picks per slot so they stay pinned at the top regardless of sorting or filters (with automatic hiding of NSFW favorites whenever NSFW is set to *Exclude*).
- **Low-Distraction Animated Cards:** Animated `.webm`, `.webp`, and `.gif` artworks display a static first frame at rest and animate only on hover or controller focus.

### 📚 Built-In Library Organizer & Backups
- **Smart Library Sidebar:** Filter between *Games*, *Software*, *Tools*, and *Hidden* items; star favorites; hide games from view; and sort by *Alphabetical*, *Recently Played*, *Hours Played*, *Disk Space*, or *Acquisition Date*.
- **Quick Library Jump:** Jump straight to any game's Steam Library page in the background while keeping the editor open.
- **Portable Profile Backups:** Export and import your complete configuration (filters, theme presets, favorite games, favorite artworks, hidden games, and SGDB ID overrides) as JSON — your API key is never exported.

### 🎨 Themes, Languages & Accessibility
- **12 Curated Themes + Custom Presets:** Switch between palettes like *Fluxuos Core* (special OLED theme with exclusive subtle café background pattern and cozy custom audio), *Steam Blue*, *Midnight*, *Midnight OLED*, *Nordic Frost*, *Crimson Velvet*, *Night City Neon*, *Umbrella Kiss*, *Bonnie & Clyde*, *The Green Hero*, *Firefly Glow*, and *Cassino Inkwell*, tweak lights/surfaces/corners, or save up to 9 presets of your own.
- **7 Languages with Auto-Detection:** English, Portuguese (Brazil), Spanish, Japanese, Korean, Russian, and French — automatically matching your Steam language or selectable per preference.
- **Adaptive On-Screen Keyboard & Audio Feedback:** Automatically uses Steam's keyboard in Big Picture / Steam Deck and Repage's built-in controller keyboard on Desktop, paired with subtle, toggleable UI navigation sounds.

---

## 📦 Installation

### Requirements
- [Steam](https://store.steampowered.com/) with [Millennium](https://github.com/SteamClientHomebrew/Millennium) installed (Windows or native Linux / Steam Deck; Flatpak and Snap Steam builds are not supported by Millennium).
- A free [SteamGridDB API Key](https://www.steamgriddb.com/profile/preferences/api).

### Setup
1. Download the latest `Repage_SteamGrid_x.x.x.zip` from the [**Releases**](../../releases) page.
2. Extract the archive into a folder named **`repage-steamgrid`** inside your Millennium `plugins` directory:
   - **Windows:** `C:\Program Files (x86)\Steam\plugins\repage-steamgrid`
   - **Linux / Steam Deck (Desktop Mode):** `~/.local/share/millennium/plugins/repage-steamgrid`
3. Restart Steam, open **Millennium → Plugins**, and enable **Repage SteamGrid**.
4. Open Repage SteamGrid (right-click any game → **Repage SteamGrid → Open**, double-click a banner, or press `Ctrl+Shift+P`), open **Settings**, paste your **SteamGridDB API key**, and click **Apply key**.

> **Linux / Steam Deck Note:** If the backend loads in Millennium Logs (`Backend loaded on linux`) but the UI does not appear on your first install, run the included `linux-fix.sh` script inside the plugin folder (it runs automatically after in-plugin updates):
> ```bash
> bash ~/.local/share/millennium/plugins/repage-steamgrid/linux-fix.sh
> ```

---

## 🎮 Controls & Shortcuts

| Action | Keyboard / Mouse | Controller (Desktop & Big Picture) |
| :--- | :--- | :--- |
| **Open / Close Panel** | `Ctrl + Shift + P` or Double-click banner | `R2/RT + L3 + R3` |
| **Navigate** | Arrow keys / Mouse | D-Pad / Left Stick |
| **Scroll Gallery / Page** | Mouse Wheel / `PageUp` / `PageDown` | Right Stick / `LT` / `RT` |
| **Apply Artwork** | Left Click / `Enter` / `Space` | `A` (Cross) |
| **Image Menu / Save to Disk** | Right Click / `Shift + F10` | `X` (Square) |
| **Show / Hide Filters** | Click *Show/Hide filters* | `Y` (Triangle) |
| **Switch Tabs** | `Ctrl + PageUp / PageDown` | `LB / RB` (`L1 / R1`) |
| **Collapse / Expand Library** | `P` | `R3` (Right Stick Click) |
| **Jump to Library Top** | `Home` (in list) | `L3` (Left Stick Click) |
| **Back / Close Menu or Panel** | `Esc` | `B` (Circle) |

---

## 📁 Plugin Structure

```text
repage-steamgrid/
├── .millennium/dist/index.js   # Compiled frontend bundle
├── backend/
│   ├── main.lua                # SteamGridDB API proxy, download cache & file I/O
│   └── icons.lua               # Icon writer & original backup restoration
├── plugin.json                 # Millennium plugin manifest
├── metadata.json               # Plugin version metadata
├── README.md                   # Overview & documentation
├── INSTALLATION.txt            # Quick installation & controls guide
├── PATCH_NOTES.txt             # Version history
├── CREDITS.md                  # Acknowledgments
└── LICENSE                     # MIT License
```

---

## 💙 Credits & Acknowledgments

- **Klastein** — Architecture, rebuild, UI/UX, controller engine, and ongoing development of Repage SteamGrid.
- **luthor112** — Creator of the original [Easy SteamGrid](https://github.com/luthor112/steam-easygrid) project.
- **ShuriZma** — Special thanks, as credited in the original project.
- **[SteamGridDB](https://www.steamgriddb.com)** — Community artwork database and API. Please respect and credit the artists.
- **[Millennium](https://github.com/SteamClientHomebrew/Millennium)** — Steam client plugin framework.
- **hatewxb (Aika theme)** — Visual inspiration for the ambient light and color-token concepts.

---

## 📄 License

Licensed under the [MIT License](LICENSE).
