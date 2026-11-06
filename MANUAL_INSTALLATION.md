# Manual Installation — DCS F10 To Waypoint 1.1.0

Use the automatic installer unless you specifically prefer a manual setup. Close DCS completely before changing files.

`<DCS Saved Games>` means the folder that contains your DCS `Config`, `Logs`, and `Scripts` folders, usually:

```text
C:\Users\<name>\Saved Games\DCS
```

## 1. Install the Export bridge

Create:

```text
<DCS Saved Games>\Scripts\DCS_F10ToWaypoint
```

Copy:

```text
dcs\DCS_F10ToWaypoint.lua
```

to:

```text
<DCS Saved Games>\Scripts\DCS_F10ToWaypoint\DCS_F10ToWaypoint.lua
```

## 2. Install the in-game overlay

Create this folder if necessary:

```text
<DCS Saved Games>\Scripts\Hooks
```

Copy:

```text
dcs\DCS_F10ToWaypointGameGUI.lua
```

to:

```text
<DCS Saved Games>\Scripts\Hooks\DCS_F10ToWaypointGameGUI.lua
```

## 3. Load the bridge from Export.lua

Open or create:

```text
<DCS Saved Games>\Scripts\Export.lua
```

Append this single line without deleting existing SRS, Tacview, or other integrations:

```lua
pcall(function() local lfs=require("lfs"); dofile(lfs.writedir()..[[Scripts\DCS_F10ToWaypoint\DCS_F10ToWaypoint.lua]]) end) -- F10W-MANAGED
```

Remove any older line ending in `M2W-MANAGED` or `DWA-MANAGED` so that only one waypoint bridge is loaded.

## 4. Allow the local user hook

Open or create:

```text
<DCS Saved Games>\Config\autoexec.cfg
```

Ensure that `userhooks` is present in `net.allow_unsafe_api`. If no setting exists, add:

```lua
if not net then net = {} end
net.allow_unsafe_api = { "userhooks" }
```

If the list already contains other values, preserve them and add `"userhooks"` once. F10W 1.1.0 does **not** require `net.allow_dostring_in`, `mission`, or `scripting` access.

If the previous version added only `net.allow_dostring_in = { "mission", "scripting" }` and no other installed script needs it, that obsolete line can be removed.

## 5. Remove superseded files

Delete the old DCS Marker To Waypoint hook and script directory if they exist:

```text
<DCS Saved Games>\Scripts\Hooks\DCS_MarkerToWaypointGameGUI.lua
<DCS Saved Games>\Scripts\DCS_MarkerToWaypoint
```

Back them up first if you want to preserve the previous version.

## 6. Start and verify

Start DCS, enter a supported aircraft, and press `Ctrl + Shift + M`.

For diagnostics, check:

```text
<DCS Saved Games>\Logs\F10W.log
<DCS Saved Games>\Logs\dcs.log
```

Search `dcs.log` for `F10W.GUI` and `F10W`.

## Manual update

With DCS closed, replace the two Lua files with files from the same release. The `Export.lua` loader and `autoexec.cfg` permission do not need to be added again.
