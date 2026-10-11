import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join, resolve, extname } from "node:path";

const { chromium } = await import(
  process.env.PLAYWRIGHT_MODULE || "playwright"
);
const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const server = createServer(async (request, response) => {
  try {
    const path = resolve(
      join(
        root,
        decodeURIComponent(new URL(request.url, "http://localhost").pathname),
      ),
    );
    if (path !== root && !path.startsWith(root + "/"))
      throw new Error("Invalid path");
    const file = path === root ? join(path, "index.html") : path;
    response.setHeader(
      "Content-Type",
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".css": "text/css",
        ".svg": "image/svg+xml",
      }[extname(file)] || "application/octet-stream",
    );
    response.end(await readFile(file));
  } catch {
    response.writeHead(404);
    response.end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}`;
let browser;
const errors = [];
const requests = [];
try {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.BROWSER_EXECUTABLE
      ? { executablePath: process.env.BROWSER_EXECUTABLE }
      : {}),
  });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 1000 },
  });
  await context.addInitScript(() => {
    window.showDirectoryPicker = async () => {
      if (window.pickerFailure)
        throw new DOMException("Denied", window.pickerFailure);
      if (!window.testDisk) {
        const { fakeDisk } = await import("/tests/fakes.js");
        window.testDisk = fakeDisk();
      }
      return window.testDisk.root;
    };
  });
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("request", (request) => requests.push(request.url()));
  await page.goto(url);
  await page.waitForFunction(() => !document.getElementById("manual").disabled);
  assert.equal(await page.locator("#import").isDisabled(), true);
  assert.equal(await page.locator("#choose-files").isDisabled(), true);
  assert.equal(
    await page
      .locator("#panel-1")
      .evaluate((node) => node.classList.contains("active-step")),
    true,
  );
  assert.equal(
    await page
      .locator("#panel-1 .section-number")
      .evaluate((node) => getComputedStyle(node).backgroundColor),
    "rgb(245, 200, 66)",
  );
  assert.equal(
    await page
      .locator("#connect")
      .evaluate((node) => node.classList.contains("primary")),
    true,
  );
  assert.equal(await page.locator(".button.primary:enabled").count(), 1);
  await page.screenshot({
    path: join(tmpdir(), "readr-importer-desktop.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Already in Data Disk mode" }).click();
  assert.equal(
    await page
      .locator("#select-drive")
      .evaluate((node) => node.classList.contains("primary")),
    true,
  );
  assert.equal(
    await page
      .locator("#connect")
      .evaluate((node) => node.classList.contains("primary")),
    false,
  );
  assert.equal(
    await page.evaluate(() => document.activeElement.id),
    "select-drive",
  );
  await page.getByRole("button", { name: "Select drive", exact: true }).click();
  await page.waitForFunction(
    () => !document.getElementById("choose-files").disabled,
  );
  assert.equal(
    await page
      .locator("#panel-2")
      .evaluate((node) => node.classList.contains("active-step")),
    true,
  );
  assert.equal(
    await page
      .locator("#panel-1")
      .evaluate((node) => node.classList.contains("active-step")),
    false,
  );
  assert.equal(
    await page
      .locator("#choose-files")
      .evaluate((node) => node.classList.contains("primary")),
    true,
  );
  assert.equal(
    await page.evaluate(() => document.activeElement.id),
    "choose-files",
  );
  assert.match(
    await page.locator("#destination").textContent(),
    /Data\/com.sellswordsoftware.readr/,
  );
  await page.locator("#file-input").setInputFiles([
    {
      name: "A good book.epub",
      mimeType: "application/epub+zip",
      buffer: Buffer.from([0x50, 0x4b, 3, 4, 9, 8, 7]),
    },
    {
      name: "a GOOD book.EPUB",
      mimeType: "application/epub+zip",
      buffer: Buffer.from([0x50, 0x4b, 3, 4, 9, 8, 7]),
    },
    {
      name: "Not an EPUB.epub",
      mimeType: "application/epub+zip",
      buffer: Buffer.from("not a zip"),
    },
  ]);
  await page.waitForFunction(() =>
    document
      .getElementById("queue-summary")
      .textContent.includes("1 book ready"),
  );
  assert.equal(
    await page
      .locator("#import")
      .evaluate((node) => node.classList.contains("primary")),
    true,
  );
  assert.equal(
    await page
      .locator("#choose-files")
      .evaluate((node) => node.classList.contains("primary")),
    false,
  );
  assert.equal(await page.evaluate(() => document.activeElement.id), "import");
  await page.locator("#duplicate-policy").selectOption("keep");
  await page.waitForFunction(() =>
    document
      .getElementById("queue-summary")
      .textContent.includes("2 books ready"),
  );
  assert.match(await page.locator("#queue").textContent(), /\(2\)\.epub/);
  await page.getByRole("button", { name: "Copy books" }).click();
  await page.waitForFunction(() => !document.getElementById("results").hidden);
  assert.match(
    await page.locator("#result-summary").textContent(),
    /2 copied.*1 not ready/,
  );
  assert.equal(await page.locator("#import").isDisabled(), true);
  assert.equal(
    await page
      .locator("#transfer")
      .evaluate((node) => node.classList.contains("active-step")),
    true,
  );
  assert.equal(
    await page
      .locator("#panel-2")
      .evaluate((node) => node.classList.contains("active-step")),
    false,
  );
  assert.equal(
    await page
      .locator("#start-over")
      .evaluate((node) => node.classList.contains("primary")),
    true,
  );
  assert.equal(
    await page.evaluate(() => document.activeElement.id),
    "start-over",
  );
  const names = await page.evaluate(() => [
    ...window.testDisk.destination.entries.keys(),
  ]);
  assert.deepEqual(names, ["A good book.epub", "a GOOD book (2).epub"]);
  assert.match(
    await page.locator("#queue").textContent(),
    /Copied and verified/,
  );
  await page.screenshot({
    path: join(tmpdir(), "readr-importer-complete.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Add more books" }).click();
  assert.equal(await page.locator("#results").isVisible(), false);
  assert.equal(await page.locator("#queue li").count(), 0);
  await page.evaluate(() => {
    window.pickerFailure = "NotAllowedError";
  });
  await page.getByRole("button", { name: "Select drive", exact: true }).click();
  await page.waitForFunction(() =>
    document
      .getElementById("connection-message")
      .textContent.includes("Permission"),
  );
  assert.equal(await page.locator("#import").isDisabled(), true);
  await page.evaluate(() => {
    window.pickerFailure = null;
  });
  await page.getByRole("button", { name: "Select drive", exact: true }).click();
  await page.waitForFunction(
    () => !document.getElementById("choose-files").disabled,
  );
  await page.locator("#file-input").setInputFiles({
    name: "Failed copy.epub",
    mimeType: "application/epub+zip",
    buffer: Buffer.from([0x50, 0x4b, 3, 4]),
  });
  await page.waitForFunction(() => !document.getElementById("import").disabled);
  await page.evaluate(() => {
    window.testDisk.destination.fail.write = new DOMException(
      "Drive full",
      "QuotaExceededError",
    );
  });
  await page.getByRole("button", { name: "Copy books" }).click();
  await page.waitForFunction(() => !document.getElementById("results").hidden);
  assert.match(
    await page.locator("#result-summary").textContent(),
    /0 copied.*1 failed/,
  );
  assert.equal(
    await page.evaluate(() =>
      window.testDisk.destination.entries.has("Failed copy.epub"),
    ),
    false,
  );

  await page.getByRole("button", { name: "Add more books" }).click();
  await page.evaluate(() => {
    delete window.testDisk.destination.fail.write;
    window.testDisk.destination.fail.afterWrite = () =>
      new Promise((resolve) => {
        window.copyStarted = true;
        window.releaseCopy = resolve;
      });
  });
  await page.getByRole("button", { name: "Select drive", exact: true }).click();
  await page.waitForFunction(
    () => !document.getElementById("choose-files").disabled,
  );
  await page.locator("#file-input").setInputFiles({
    name: "Cancelled book.epub",
    mimeType: "application/epub+zip",
    buffer: Buffer.from([0x50, 0x4b, 3, 4]),
  });
  await page.waitForFunction(() => !document.getElementById("import").disabled);
  await page.getByRole("button", { name: "Copy books" }).click();
  await page.waitForFunction(() => window.copyStarted);
  assert.equal(
    await page
      .locator("#transfer")
      .evaluate((node) => node.classList.contains("active-step")),
    true,
  );
  assert.equal(await page.locator(".button.primary:enabled").count(), 0);
  assert.equal(await page.evaluate(() => document.activeElement.id), "cancel");

  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await page.evaluate(() => window.releaseCopy());
  await page.waitForFunction(() => !document.getElementById("results").hidden);
  assert.match(
    await page.locator("#result-summary").textContent(),
    /0 copied.*1 cancelled/,
  );
  assert.equal(
    await page.evaluate(() =>
      window.testDisk.destination.entries.has("Cancelled book.epub"),
    ),
    false,
  );
  assert.equal(
    await page.evaluate(() => window.testDisk.destination.entries.size),
    2,
  );

  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  await page.waitForFunction(() => !document.getElementById("manual").disabled);
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth > innerWidth,
    ),
    false,
  );
  await page.screenshot({
    path: join(tmpdir(), "readr-importer-mobile.png"),
    fullPage: true,
  });
  const unsupported = await context.newPage();
  unsupported.on("pageerror", (error) => errors.push(error.message));
  await unsupported.addInitScript(() => {
    window.showDirectoryPicker = undefined;
  });
  await unsupported.goto(url);
  await unsupported.waitForFunction(
    () => !document.getElementById("capability").hidden,
  );
  assert.match(
    await unsupported.locator("#capability").textContent(),
    /manual/,
  );
  assert.equal(await unsupported.locator("#connect").isDisabled(), true);
  assert.equal(await unsupported.locator("#manual").isDisabled(), true);
  const policyProbe = await context.newPage();
  await policyProbe.goto(url);
  const policy = await policyProbe.evaluate(async () => {
    const violations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      if (event.effectiveDirective === "connect-src")
        violations.push(event.blockedURI);
    });
    const discovery = await fetch(
      "/.well-known/appspecific/com.chrome.devtools.json",
    );
    const blocked = [];
    for (const target of ["/config.js", "https://example.com/"]) {
      try {
        await fetch(target);
        blocked.push(false);
      } catch {
        blocked.push(true);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 30));
    return { status: discovery.status, blocked, violations };
  });
  assert.equal(
    policy.status,
    404,
    "Optional DevTools discovery must reach the local server",
  );
  assert.deepEqual(policy.blocked, [true, true]);
  assert.equal(policy.violations.length, 2);
  assert.ok(
    policy.violations.every(
      (target) => !target.endsWith("com.chrome.devtools.json"),
    ),
  );
  await policyProbe.close();
  assert.deepEqual(errors, []);
  assert.ok(
    requests.every((request) => request.startsWith(url)),
    "Unexpected external request",
  );
  console.log(
    "PASS: browser import, duplicates, invalid EPUB, results, permission denial, failed copy, cancellation, reset, narrow layout, unsupported browser, restricted DevTools discovery, and no external app requests.",
  );
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
