# CombatClient
Modular Luau and target-assist system.  Use at your own risks.

# SmartCamera-CombatClient

# SmartCamera-CombatClient

A modular Luau camera and target-assist controller integrated with the **Obsidian** UI library.

## Features
- **Priority Modes:** Choose between `Smart` (blended distance + crosshair angle with lock stickiness), `Nearest`, and `Crosshair`.
- **Target Filtering:** Toggle Players and NPCs independently, filter same team, prefer `Head` or `HumanoidRootPart`, and adjust max FOV angle and distance.
- **Toggleable Wall Check:** Raycast line-of-sight check with a UI toggle to block or allow targets behind walls.
- **State & Session Safety:** Stops camera/assist updates when the local character dies or respawns, skips dead targets, and cleanly unbinds/cleans up sessions via `Destroy()`.

## Controls (Obsidian UI)
- **Smart Camera:** Enable/disable assist, switch mode (`Camera`, `Raycast`, `Remote`), choose target priority, and tune smoothness / lock hold duration.
- **Target Filters:** Toggle `Target Players`, `Target NPCs`, `Prefer Head`, `Wall Check`, and `Ignore Same Team`, plus angle and distance sliders.
- **Visuals & Session:** Toggle highlights, adjust ESP distance, or run `Unload & Cleanup` to tear down connections and UI.
