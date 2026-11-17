# Repage SteamGrid

![Version](https://img.shields.io/badge/version-5.2.0-438FCB?style=flat-square)
![Framework](https://img.shields.io/badge/Millennium-Steam%20Plugin-1b2838?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20Steam%20Deck-2a475e?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-49C695?style=flat-square)

**Repage SteamGrid** is a fast, lightweight artwork manager for the Steam client built on top of [Millennium](https://github.com/SteamClientHomebrew/Millennium) and powered by [SteamGridDB](https://www.steamgriddb.com). Rebuilt from the ground up from *Easy SteamGrid*, it lets you browse, preview, favorite, save, and apply custom **Grids**, **Wide Grids**, **Heroes**, **Logos**, and **Icons** directly inside Steam — on Desktop, Big Picture, and Steam Deck.

---

## ✨ Key Features

- **All 5 Steam Artwork Slots:** Manage vertical Grids (`600×900`), Wide Grids (`920×430`), Heroes (`1920×620` / `3840×1240`), Logos, and App Icons (including non-Steam shortcuts).
- **Context-Aware Smart Opening:**
  - Double-click a game's library banner to open directly on the **Hero** tab.
  - Right-click a vertical cover in your grid to open on the **Grid** tab.
  - Right-click a horizontal cover (Recent / Featured / Big Picture) to open on the **Wide Grid** tab.
  - Right-click a game in the left sidebar list to open on the **Icon** tab.
- **Smooth 60+ FPS Virtualized Gallery:**
  - Synchronized card + preview reveal in strict left-to-right order without layout shifts or blank holes.
  - Static first-frame `<canvas>` snapshots for animated `.webm`, `.webp`, and `.gif` artwork — animations play only on hover or controller focus, keeping CPU/GPU usage low.
  - Dedicated **Performance Mode** in Settings that disables blurs, ambient lights, and animations for low-spec hardware.
- **Local Files & Favorite Artworks:**
  - Apply custom `.png`, `.jpg`, `.webp`, `.gif`, `.ico`, or `.webm` files from your computer (stored in IndexedDB and pinned to the top of the slot).
  - Favorite any SteamGridDB image so it stays pinned at the top of the gallery (with automatic NSFW hiding when the NSFW filter is set to *Exclude*).
- **Author Priority & Filtering:**
  - Prioritize or exclude specific artists via ordered tags or directly from any image's right-click menu.
  - Instant 0 ms client-side sorting (*Score*, *Newest*, *Author*, *Resolution*) and filtering (*NSFW*, *Humor*, *Epilepsy*, *Types*, *Formats*, *Styles*, *Dimensions*).
- **12 Curated Themes + Custom Presets:**
  - Includes *Steam Blue*, *Midnight*, *Midnight OLED*, *Nordic Frost*, *Crimson Velvet*, *Emerald Pine*, *Night City Neon*, *Umbrella Kiss*, *Bonnie & Clyde*, *The Green Hero*, *Firefly Glow*, and *Cassino Inkwell*, plus up to 9 user-saved presets, surface finishes (*Glass*, *Frosted*, *Solid*), light intensity, and corner styles.
- **Full Controller & Big Picture / Steam Deck Support:**
  - Complete D-pad spatial navigation across library, tabs, filters, color picker, and virtualized grid.
  - Auto-selects games when browsing the library with the D-pad and returns focus to the active game when pressing **B**.
  - Adaptive on-screen keyboard (uses Steam's native keyboard in Big Picture / Steam Deck and Repage's controller keyboard on Desktop).
- **Library Management & Profile Backup:**
  - Filter by Games / Software / Tools, favorite games, hide/unhide games, and sort by Alphabetical, Recently Played, Hours Played, Disk Space, or Acquisition Date.
  - Export and import your complete profile (settings, custom presets, favorites, hidden games, and SGDB ID overrides) as JSON without exposing your API key.
- **7 Interface Languages:**
  - English (`en`), Portuguese - Brazil (`pt-BR`), Spanish (`es`), Japanese (`ja`), Korean (`ko`), Russian (`ru`), and French (`fr`), with automatic Steam language detection.

---

## 📦 Installation

### Requirements
- [Steam](https://store.steampowered.com/) with [Millennium](https://github.com/SteamClientHomebrew/Millennium) installed.
- A free [SteamGridDB API Key](https://www.steamgriddb.com/profile/preferences/api).

### Steps
1. Download the latest `Repage_SteamGrid_x.x.x.zip` from the [**Releases**](../../releases) page.
2. Extract the contents into a folder named **`repage-steamgrid`** inside your Millennium `plugins` directory:
   - **Windows:** `C:\Program Files (x86)\Steam\plugins\repage-steamgrid`
   - **Linux / Steam Deck (Desktop Mode):** `~/.local/share/millennium/plugins/repage-steamgrid`
3. Restart Steam, open **Millennium → Plugins**, and enable **Repage SteamGrid**.
4. Open Repage SteamGrid (**right-click any game → Repage SteamGrid → Open**, double-click a game banner, or press `Ctrl+Shift+P`), go to the **Settings** tab, paste your **SteamGridDB API key**, and click **Apply key**.

---

## 🎮 Controls & Shortcuts

| Action | Keyboard / Mouse | Controller (Desktop & Big Picture) |
| :--- | :--- | :--- |
| **Open / Close Panel** | `Ctrl + Shift + P` or Double-click game banner | `R2/RT + L3 + R3` |
| **Navigate** | Arrow keys / Mouse | D-Pad / Left Stick |
| **Scroll Gallery / Page** | Mouse Wheel / `PageUp` / `PageDown` | Right Stick / `LT` / `RT` |
| **Apply Artwork** | Left Click / `Enter` / `Space` | `A` (Cross) |
| **Image Context Menu / Save** | Right Click / `Shift + F10` | `X` (Square) |
| **Show / Hide Filters** | Click *Show/Hide filters* | `Y` (Triangle) |
| **Switch Tabs** | `Ctrl + PageUp / PageDown` | `LB / RB` (`L1 / R1`) |
| **Toggle Library Sidebar** | `P` | `R3` (Right Stick Click) |
| **Jump to Library Top** | `Home` (in list) | `L3` (Left Stick Click) |
| **Back / Close Menu or Panel** | `Esc` | `B` (Circle) |

---

## 📁 Plugin Structure

```text
repage-steamgrid/
├── .millennium/Dist/index.js   # Compiled frontend bundle loaded by Millennium
├── backend/
│   ├── main.lua                # Lua backend (API proxy, temp cache, file I/O)
│   └── icons.lua               # Icon writer & backup restoration
├── plugin.json                 # Millennium plugin manifest
├── metadata.json               # Plugin version metadata
├── README.md                   # Documentation
├── INSTALLATION.txt            # Quick installation & controls guide
├── PATCH_NOTES.txt             # Version changelog
├── CREDITS.md                  # Acknowledgments
└── LICENSE                     # MIT License
```

---

## 💙 Credits & Acknowledgments

- **Klastein** — Rebuild, architecture, acrylic UI, controller engine, and ongoing development of Repage SteamGrid.
- **luthor112** — Author of the original [Easy SteamGrid](https://github.com/SteamClientHomebrew) ([steam-easygrid](https://github.com/luthor112/steam-easygrid)) project.
- **ShuriZma** — Special thanks, as credited in the original project.
- **[SteamGridDB](https://www.steamgriddb.com)** — Community artwork database and API. Please respect and support the artists who create and share their work.
- **[Millennium](https://github.com/SteamClientHomebrew/Millennium)** — Steam client homebrew framework.
- **hatewxb (Aika theme)** — Visual inspiration for the ambient light and acrylic surface concepts reconstructed for Repage.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
