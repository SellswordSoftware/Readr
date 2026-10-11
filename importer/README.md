# readr EPUB importer

A static, browser interface for adding EPUBs to readr on
Playdate. Plain HTML, CSS, and JavaScript.
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
to skipping existing names; **Keep both** previews numbered copies, and
**Overwrite existing** replaces matching books while preserving the existing
filename. Filenames in the list can be edited. When queued books share a name,
overwrite copies them in order, leaving the last book. Replacements do not use
another library slot. Folders and reading-state files are not replaced.

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
