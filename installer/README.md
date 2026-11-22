# Repage SteamGrid Setup (.exe) — Source Code

This directory contains the complete source code for **`Repage_SteamGrid_Setup.exe`**, the standalone portable Windows installer for Repage SteamGrid.

## Files
- **`Program.cs`** — Native C# (.NET Framework 4.x) host, GitHub Release & SHA-256 verifier, transactional file staging & rollback engine, Millennium `config.json` integration, and local HTTP bridge.
- **`ui.html`** — Embedded WebView2 user interface (HTML/CSS/JS) with 7-language localization and WebAudio procedural sound effects.

## Build & Reproducibility
The executable is compiled on Windows using the built-in .NET Framework 4.x compiler (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`) and the official NuGet package [`Microsoft.Web.WebView2`](https://www.nuget.org/packages/Microsoft.Web.WebView2) (v1.0.2903.40), embedding `Microsoft.Web.WebView2.Core.dll`, `Microsoft.Web.WebView2.WinForms.dll`, `WebView2Loader.dll` (x64), and the compiled `ui.html` as managed resources (`-target:winexe`).
