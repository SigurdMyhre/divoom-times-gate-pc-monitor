# Divoom Times Gate – API notes

Device: Times Gate (5 × 128×128 LCDs, index 0–4, left to right), reached at its LAN IP (`192.168.2.169` in the examples below; use your own).
Divoom's official Times Gate guide has no payload details. Everything below was found by testing against this device's firmware.

## Endpoint
- `POST http://192.168.2.169:9000/divoom_api` with a JSON body. Port 80 / `/post` (the Pixoo docs) is closed on this device.
- The server (Libuhttpd) closes every connection, so send each request on a fresh one (`-DisableKeepAlive`).
- Known command → `ReturnCode: 0` (the reply also carries `DeviceId` and `DeviceType: "LCD"`). Unknown command → `ReturnCode: 1, "Only accept JSON parameters"`.
- **Setter commands treat missing values as 0.** Always send every parameter.

## Showing pictures (works)
1. `{"Command":"Channel/SetIndex","SelectIndex":3}` switches to the custom channel. Without it, pictures are ignored.
2. `{"Command":"Draw/ResetHttpGifId"}`
3. `{"Command":"Draw/SendHttpGif","LcdArray":[1,0,0,0,0],"PicNum":1,"PicWidth":128,"PicOffset":0,"PicID":1,"PicSpeed":1000,"PicData":"<base64 JPEG>"}`
   - `PicData` must be a **base64 JPEG**. Raw RGB shows only a loading spinner.
   - `LcdArray` picks which screens get the picture.
   - Animation: same `PicID`, `PicNum` = frame count, `PicOffset` = frame index.
   - `Draw/GetHttpGifId` returns no `PicId` on this firmware, so the script counts IDs itself.

## Update behaviour (found while building pcmon.ps1)
- One picture takes ~0.46 s for the device to accept (HTTP round trip); 5 screens ≈ 2.3 s.
- Updating one screen leaves the others untouched.
- Re-sending with a PicID the device has already seen is **ignored** (screen freezes), so every update needs a new ID.
- **JPEG size must stay in a window of roughly 5–6.5 KB**, or the screen flashes a loading spinner for ~0.5 s before the picture appears. Too small (~4 KB, the device also answers these faster, ~400 ms vs ~720 ms) and too large (7–10 KB) both trigger it. Fix in pcmon.ps1: `Encode-Jpeg` lowers the quality until the file is ≤ 6.5 KB, then `Pad-Jpeg` pads to ≥ 6 KB with a COM (comment) segment after the SOI marker. With that, pictures can be sent back-to-back with no pause. (Pauses between pictures, `PicSpeed` and send order only looked like they helped.)

## Other commands
- Accepted: `Channel/SetBrightness {Brightness}`, `Channel/OnOffScreen {OnOff}`, `Channel/GetClockInfo {LcdIndex}` (returns ClockId, Brightness), `Channel/SetClockSelectId`, `Channel/SetCustomPageIndex`, `Channel/SetEqPosition`, `Channel/SetCustom`, `Channel/Set5LcdChannelType`, `Draw/ClearHttpText`, `Device/PlayGif`, `Device/SetUTC`, `Device/SetHighLightMode`, `Tools/SetTimer`, `Sys/GetConf`
- Rejected: `Draw/SendHttpText`, `Draw/SendHttpItemList`, `Device/PlayTFGif`, `Channel/SetLcdsIndependence`, `Device/GetDeviceInfo`, `Device/Hello`
- Avoid: `Draw/SendRemote` and `Draw/UseHTTPCommandSource` dropped the connection or briefly knocked the device offline.

## Open questions
- Does sending an animation to one screen clear the other screens (because of `ResetHttpGifId`)?
- Can each screen be put on its own channel? (`Channel/Set5LcdChannelType` exists, but its parameters are unknown.)
- Text overlays: `SendHttpText` is rejected, so text has to be drawn into the image.

## Scripts
- `divoom.ps1 -Mode random|image|anim [-ImagePath file] [-Screens "0,1,2,3,4"]` – push test pictures.
- `pcmon.ps1 [-Style retro|big|duo|gauge|detail] [-Demo] [-Preview] [-Log] [-Layout 0,1,2,3,4]` – default style `retro` (hand-drawn 5×7 pixel font in `$PxRows`, 12-segment VU bar, pixel border, scanlines, neon palette). `big` is the same layout with smooth Bahnschrift text. Rings proved too tight for 128 px: wide values like `34 KB/s` or `19:38` collide with a 270° ring. Fonts: Bahnschrift SemiBold (+ Condensed), included with Windows. – PC status dashboard (CPU, GPU, memory/disks, network, clock). Needs LibreHardwareMonitor running as admin with its web server on port 8085 for CPU temperature/power; without it the CPU tile shows `--`.
- `install-autostart.ps1` (run as admin) registers two logon tasks: **Divoom LHM** (LibreHardwareMonitor, elevated, no UAC prompt) and **Divoom pcmon** (pcmon.ps1, 20 s after logon, auto-restart on crash). The pcmon task uses an S4U principal ("run whether user is logged on or not", no password) so it has no desktop session and therefore no window: on Windows 11 with Windows Terminal as default host, `-WindowStyle Hidden` alone leaves a visible terminal window. `-Uninstall` removes them.
  - Stop/start the dashboard: `Stop-ScheduledTask 'Divoom pcmon'` / `Start-ScheduledTask 'Divoom pcmon'`. Stop it before running pcmon.ps1 manually, or two instances fight over the screens.
  - The task runs the script from this folder, so edits to pcmon.ps1 take effect at the next (re)start of the task.
- LibreHardwareMonitor is installed via winget under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\LibreHardwareMonitor.*\`; its `LibreHardwareMonitor.config` enables the web server and tray/minimised start.
