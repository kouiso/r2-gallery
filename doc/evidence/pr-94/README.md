# PR #94 device evidence — Android Pixel (2A091FDH300C0J)

KMP composeApp debug build, 2026-10-12. All shots show the new 4-tab
bottom bar (写真 / アルバム / 取り込み / 設定).

- `01-import-start.png` — cold start lands on 取り込み (start destination
  unchanged); no connection configured → ConnectScreen, Import tab lit.
- `02-settings-lock-gate.png` — 設定 tab still behind the lock gate:
  device has no screen credential → NoCredentialScreen shown.
- `03-albums-connection-gate.png` — アルバム tab still behind the
  connection gate: NeedsConnection shows ConnectScreen, アルバム tab lit.

The live-connection shots (アルバム grid / 写真 tab with real library content) were
removed when the repository was published, because they showed private library images.

Note: landscape layout currently clips the connect form's buttons under
the nav bar on this device — pre-existing constraint, out of scope here.
