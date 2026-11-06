# DCS F10 To Waypoint 1.1.0 — User Guide

## Purpose

DCS F10 To Waypoint transfers a position selected on the F10 map into a supported aircraft's waypoint system. The entire workflow stays inside DCS.

A complete example is available in the [demonstration video](https://www.youtube.com/watch?v=nI1SDAzudL4).

F10W uses map **points**, not map markers. Existing marker lists cannot be read reliably by local client hooks on every multiplayer server because DCS restricts the required mission APIs. F10W therefore reads the coordinates produced by DCS's native F10 coordinate window after you select a position.

## Standard workflow

1. Join a mission and enter a supported aircraft.
2. Wait until the cockpit has finished loading.
3. Press **Ctrl + Shift + M** to open the F10W overlay.
4. Open the F10 map. The overlay remains visible over the map.
5. Hold **Left Alt** and left-click the exact position you want.
6. Verify the position in the DCS **COORDINATES** window and press **COPY**.
7. Confirm that the new point immediately appears in the overlay. Repeat the previous two steps to acquire additional points if needed.
8. Return to the cockpit and choose the acquired point from **F10 point**.
9. Use the large `<` and `>` controls to choose the destination waypoint.
10. Press **Insert**.
11. Leave the aircraft avionics controls untouched until the overlay reports success or an error.

Acquisition is automatic; no paste field or Import button is required. Opening the overlay before F10 is recommended because every copied point then appears in the list in real time.

## Overlay controls

- **F10 point**: points acquired during the current cockpit session. The latest point is selected automatically.
- **Waypoint destination**: destination number and its aircraft-specific name, such as WP, STPT, W, PREP, or DEST.
- **Insert**: starts the avionics sequence. It remains disabled while an operation is active.
- **Hide**: hides the overlay. `Ctrl + Shift + M` shows it again.
- **Remove selected point**: removes the selected point from the current list.
- **LAT/LON (DDM)**: latitude and longitude in degrees and decimal minutes.
- **Elevation**: terrain elevation in metres and feet.

The overlay starts hidden and automatically hides when the mission ends.

## Status messages

- **Select a point in F10 and press COPY.** — no point has been acquired in this cockpit session.
- **DCS COPY imported automatically.** — the selected F10 position is ready.
- **INSERTION IN PROGRESS** — the avionics sequence is running; do not touch the relevant controls.
- **WP INSERTED SUCCESSFULLY** — the aircraft confirmed completion.
- **ERROR: ...** — the sequence stopped or could not reach the required avionics state. Read the explanation and check the logs if needed.

F10W prevents a second insertion until the active operation has completed or cancellation has been confirmed. This avoids overlapping button sequences.

## Supported aircraft

Tested:

- F/A-18C Hornet: WP1-WP59.
- F-16C Viper: STPT1-STPT99.
- F-14A/B Tomcat: WP1-WP3.
- F-14B(U): flight-plan WP1-WP3.
- F-4E Phantom II: TARGET1-TARGET2.
- AH-64D Apache: W01-W50.
- Mirage F1EE: WP1-WP9.
- UH-60L mod 2.1.x: WP00-WP69.
- A-4E-C mod: DEST1-DEST2.

Experimental:

- A-10C / A-10C II: WP0-WP40.
- AJS-37 Viggen: B1-B9.
- JF-17 Thunder: DST1-DST49.
- Mirage 2000C: PREP1-PREP20.
- AV-8B N/A Harrier: WP1-WP99.
- F-15E Strike Eagle: A1-A99.

“Experimental” means that the integration is implemented but has not yet been confirmed by a successful user test and may need adjustments.

### F/A-18C notes

F10W automatically opens the required avionics pages, enables **PRECISE**, detects `LATLN DCML` or `LATLN SEC`, enters the coordinates at the precision accepted by the selected format, and enters terrain elevation in feet.

## Multiplayer and server requirements

No server-side script, mission modification, special slot, or cooperation from the server administrator is required. F10W operates on the local client data copied by DCS.

The server must allow the normal F10 map and DCS coordinate window needed by the player. Mission settings may restrict what the F10 map displays, but they do not change F10W's installation.

## Troubleshooting

### The overlay does not appear

- Confirm that DCS was closed during installation.
- Enter a supported aircraft and allow the cockpit to finish loading.
- Press `Ctrl + Shift + M`.
- Check `Saved Games\DCS\Logs\F10W.log` for `DCS F10 To Waypoint GameGUI 1.1.0 started`.

### The point does not appear

- Use **Left Alt + left click** on the F10 map.
- Press **COPY** in DCS's coordinate window; copying text manually from another source is not the supported workflow.
- Make sure you are already in a supported aircraft.
- Copy the point again after changing cockpit slot or starting a new mission, because points are intentionally cleared between cockpit sessions.

### Insertion fails

- Do not operate the avionics while insertion is running.
- Make sure the aircraft and its navigation equipment are powered and ready.
- Read the red error message.
- Check `Saved Games\DCS\Logs\F10W.log` and search `Saved Games\DCS\Logs\dcs.log` for `F10W`.

On timeout, F10W requests cancellation and keeps **Insert** locked until the Export bridge confirms that the old sequence stopped. If stop confirmation never arrives, restart the mission before trying again.

## Privacy and networking

F10W communicates only between its two local DCS scripts through UDP on `127.0.0.1`. It does not send coordinates over the internet and does not require a firewall exception.
