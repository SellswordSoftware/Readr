# readr EPUB importer

A static, browser interface for adding EPUBs to readr on
Playdate. Plain HTML, CSS, and JavaScript; no runtime dependencies or backend.
Book contents stay on the computer and the selected Playdate drive.

## Preview

From the repository root:

```sh
python3 -m http.server 8080 --directory importer
```

Open `http://localhost:8080` in desktop Chrome or Edge. A localhost origin permits
the browser APIs used here; opening the HTML directly as a file is not supported.

Chrome DevTools may request `/.well-known/appspecific/com.chrome.devtools.json`.
The policy permits this exact path on localhost and 127.0.0.1 at any port. A 404
is harmless: this tool does not configure an automatic DevTools workspace.

Install and launch readr once, connect and unlock the Playdate, and choose
**Connect Playdate** to request Data Disk mode. Alternatively, enter that mode
through the device's Settings → System menu. Select the mounted drive itself,
then select EPUBs and copy. Eject through the operating system before exiting
Data Disk mode and reopening readr.

The selected drive must contain `Games`, `Data`, and the existing
`Data/com.sellswordsoftware.readr` directory. Books are copied directly into that
last directory. The importer does not create an installation or data directory.
Filename and library limits match the current reader. Collision policy defaults
to skipping existing names; **Keep both** previews numbered copies. Filenames in
the list can be edited. Existing books and reading-state files are not replaced.

## Verification

With Node.js 24 or newer, from the repository root:

```sh
node importer/tests/importer.test.js
```

The tests use in-memory filesystem and serial adapters to check the reader
contract, filename policy, duplicate/capacity handling, bounded copying,
verification, cancellation, cleanup, and serial command handling.

For browser regression checks, install Playwright as a development-only tool in
the importer directory (the deployed site does not need it):

```sh
cd importer
npm install --no-save --package-lock=false playwright
npx playwright install chromium
npm run test:browser
```

The browser test starts its own localhost server and uses a simulated drive. It
checks the user flow, permission errors, copying failures, cancellation, narrow
layout, unsupported browsers, and absence of external requests. It writes
preview screenshots to the system temporary directory. An existing Playwright
installation can be supplied with `PLAYWRIGHT_MODULE`; an existing Chromium
executable can be supplied with `BROWSER_EXECUTABLE`.

No test writes to a real Playdate. The serial implementation uses USB VID
`0x1331`, PID `0x5740`, 115200 baud, and `datadisk\n`, as documented by
[Playdate USB console research](https://github.com/cranksters/playdate-reverse-engineering/blob/main/usb/usb.md).
Confirm those values and disconnect behavior on the shipping firmware.

## GitHub Pages

Publish the contents of this directory as static files, preserving relative
paths. The runtime files are `index.html`, `style.css`, `icon.svg`, `app.js`,
`config.js`, `files.js`, `disk.js`, and `serial.js`. Include `.nojekyll` at the
published root when deploying through a branch. Tests, node_modules, package
metadata, and this README need not be published.

Enable HTTPS. A project subpath also works: all assets use relative paths.
Do not embed the importer in an iframe. There are no credentials, upload
endpoints, external fonts, analytics, or third-party runtime scripts. A content
security policy blocks app network connections except Chrome’s optional localhost
DevTools workspace-discovery endpoint. This does not enable general same-origin
or external fetches.

## Remaining release checks

Browser and adapter tests establish application behavior, not actual removable
media durability. Before publishing, test the deployed HTTPS URL against a real
Playdate on each supported desktop OS/browser combination:

- Automatic serial reboot and the manual disk-mode route.
- First launch creating the expected data folder, then successful book discovery.
- Copying large and mixed-size EPUBs, verifying bytes, ejecting, and opening them.
- Cancel, unplug, disk-full, tab-close, and permission recovery, including leftover
  entries on the actual filesystem.
- Wrong-drive selection, read-only media, cable problems, and serial port conflicts.
- Browser temporary-file behavior and space needed while a writable stream closes.

The File System Access API has no portable exclusive-create operation. The
importer rechecks names immediately before creation, refuses a nonempty entry
that appears during creation, and uses a same-origin Web Lock when available.
Keep other file managers and copying tools out of readr's folder during import;
this cannot provide a filesystem-wide lock against other processes.

The layout check prevents ordinary folder-selection mistakes. It does not prove
that the chosen folder is on a physical Playdate. Format checks identify an
EPUB-looking ZIP, not full readr compatibility or DRM status.
