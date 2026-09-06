# PR #10249 — Support per-monitor wallpapers
Autor: DCPRevere
Estado: OPEN
URL: https://github.com/omacom/omarchy/pull/10249
Fork salvo em: https://github.com/vitorcanoas/omarchy (branch per-monitor-wallpapers)

---

Allow a portrait wallpaper on vertical displays and a landscape wallpaper on horizontal displays, with overrides for named monitors in `shell.json`.

Named overrides take precedence over orientation defaults. Unconfigured displays and images that cannot load fall back to the theme wallpaper. Overrides stay fixed when cycling backgrounds or changing themes, while existing rendering and transitions are preserved.

