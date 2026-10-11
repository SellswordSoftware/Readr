import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { config } from "../config.js";
import { fileError, nameError, nameKey, planQueue } from "../files.js";
import { resolveDestination, listEntries, copyFile } from "../disk.js";
import { requestDataDisk } from "../serial.js";
import { FakeDirectory, FakeFileHandle, fakeDisk, epub } from "./fakes.js";

const item = (name, error = "") => ({ name, file: epub(name), error });

test("reader contract matches importer destination and limits", async () => {
  const [info, source] = await Promise.all(
    ["../../pdxinfo", "../../src/storage/library.zig"].map((path) =>
      readFile(new URL(path, import.meta.url), "utf8"),
    ),
  );
  assert.match(
    info,
    new RegExp(`^bundleID=${config.bundleId.replaceAll(".", "\\.")}\\s*$`, "m"),
  );
  assert.match(source, new RegExp(`capacity = ${config.maxBooks};`));
  assert.match(
    source,
    new RegExp(`max_path_bytes = ${config.maxNameBytes + 1};`),
  );
});

test("UTF-8 filename boundary counts bytes, not characters", () => {
  assert.equal(nameError(`${"é".repeat(61)}.epub`), "");
  assert.match(nameError(`${"é".repeat(62)}.epub`), /shorter/);
  assert.equal(nameError(`${"a".repeat(122)}.epub`), "");
  assert.match(nameError(`${"a".repeat(123)}.epub`), /shorter/);
  assert.equal(nameKey("CAFÉ.epub"), nameKey("cafe\u0301.EPUB"));
});

test("reject unsafe names while accepting ordinary Unicode and uppercase extensions", () => {
  for (const name of [
    "../book.epub",
    "a:b.epub",
    "a\\b.epub",
    "a\u0000.epub",
    "CON.epub",
    "lpt1.epub",
    ".hidden.epub",
    " book.epub",
    "x.epub ",
    "x.epub.",
  ])
    assert.notEqual(nameError(name), "", name);
  assert.equal(nameError("小さな本.EPUB"), "");
});

test("preliminary format checks reject empty, disguised, and non-EPUB files", async () => {
  assert.equal(await fileError(epub()), "");
  assert.match(await fileError(epub("book.epub", [])), /empty/);
  assert.match(await fileError(epub("book.epub", [1, 2, 3, 4])), /archive/);
  assert.match(await fileError(epub("book.pdf")), /EPUB/);
});

test("duplicates include case variants, directories, and earlier queued names", () => {
  const rows = planQueue(
    [
      item("Book.epub"),
      item("new.epub"),
      item("NEW.EPUB"),
      item("folder.epub"),
    ],
    [
      { name: "book.EPUB", kind: "file" },
      { name: "folder.epub", kind: "directory" },
    ],
  );
  assert.deepEqual(
    rows.map((row) => row.status),
    ["skipped", "ready", "skipped", "skipped"],
  );
});

test("keep-both names are deterministic, bounded, and reserved across a batch", () => {
  const rows = planQueue(
    [item("book.epub"), item("book.epub")],
    [
      { name: "book.epub", kind: "file" },
      { name: "book (2).epub", kind: "file" },
    ],
    "keep",
  );
  assert.deepEqual(
    rows.map((row) => row.destination),
    ["book (3).epub", "book (4).epub"],
  );
  const long = `${"a".repeat(122)}.epub`;
  assert.equal(
    planQueue([item(long)], [{ name: long, kind: "file" }], "keep")[0].status,
    "invalid",
  );
});

test("library capacity counts existing EPUB files and accepted additions only", () => {
  const entries = Array.from({ length: 254 }, (_, i) => ({
    name: `${i}.epub`,
    kind: "file",
  }));
  entries.push(
    { name: "settings.bin", kind: "file" },
    { name: "folder.epub", kind: "directory" },
  );
  const rows = planQueue(
    [item("bad.epub", "Not readable"), item("a.epub"), item("b.epub")],
    entries,
  );
  assert.deepEqual(
    rows.map((row) => row.status),
    ["invalid", "ready", "invalid"],
  );
});

test("only existing Playdate layout resolves; never create missing directories", async () => {
  const { root, destination } = fakeDisk();
  assert.equal((await resolveDestination(root)).directory, destination);
  assert.deepEqual(root.created, []);
  await assert.rejects(
    resolveDestination(new FakeDirectory("Downloads")),
    /Select the Playdate drive/,
  );
  await assert.rejects(
    resolveDestination(
      new FakeDirectory("Playdate", [
        new FakeDirectory("Games"),
        new FakeDirectory("Data"),
      ]),
    ),
    /Install and open readr/,
  );
});

test("copy uses bounded chunks, closes, and verifies all bytes", async () => {
  const { destination } = fakeDisk();
  const file = epub();
  const progress = [];
  await copyFile(destination, file, "book.epub", {
    chunkBytes: 3,
    onProgress: (update) => progress.push(update),
  });
  const copied = destination.entries.get("book.epub");
  assert.deepEqual(copied.writes, [3, 3, 3]);
  assert.equal(copied.closed, true);
  assert.deepEqual(await copied.blob.arrayBuffer(), await file.arrayBuffer());
  assert.ok(progress.some((update) => update.phase === "verifying"));
  assert.equal(progress.at(-1).bytes, file.size);
});

test("late collisions and full libraries are never overwritten", async () => {
  const { destination } = fakeDisk();
  const old = new FakeFileHandle("BOOK.epub", new Blob(["keep me"]));
  destination.entries.set(old.name, old);
  await assert.rejects(copyFile(destination, epub(), "book.epub"), /appeared/);
  assert.equal(await old.blob.text(), "keep me");
  assert.deepEqual(destination.created, []);
  for (let i = 0; i < 254; i += 1)
    destination.entries.set(`${i}.epub`, new FakeFileHandle(`${i}.epub`));
  await assert.rejects(copyFile(destination, epub(), "new.epub"), /full/);
});

test("cancelling between chunks aborts and removes only the new entry", async () => {
  const { destination } = fakeDisk();
  const old = new FakeFileHandle("old.epub", new Blob(["original"]));
  destination.entries.set(old.name, old);
  const controller = new AbortController();
  destination.fail.afterWrite = () => controller.abort();
  await assert.rejects(
    copyFile(destination, epub(), "new.epub", {
      chunkBytes: 3,
      signal: controller.signal,
    }),
    { name: "AbortError" },
  );
  assert.deepEqual(destination.removed, ["new.epub"]);
  assert.equal(await old.blob.text(), "original");
});

for (const phase of ["open", "write", "close"])
  test(`${phase} failure cleans the new entry and keeps existing files`, async () => {
    const { destination } = fakeDisk();
    destination.entries.set(
      "settings.bin",
      new FakeFileHandle("settings.bin", new Blob(["settings"])),
    );
    destination.fail[phase] = new DOMException(
      "Disk full",
      "QuotaExceededError",
    );
    await assert.rejects(copyFile(destination, epub(), "new.epub"), {
      name: "QuotaExceededError",
    });
    assert.deepEqual(await listEntries(destination), [
      { name: "settings.bin", kind: "file" },
    ]);
  });

test("byte corruption with matching file size fails verification", async () => {
  const { destination } = fakeDisk();
  destination.fail.corrupt = true;
  await assert.rejects(
    copyFile(destination, epub("book.epub", [0x50, 0x4b, 3, 4]), "new.epub"),
    /did not match/,
  );
  assert.deepEqual(destination.removed, ["new.epub"]);
});

test("unplugged drive cleanup failure reports the exact leftover name", async () => {
  const { destination } = fakeDisk();
  destination.fail.write = new DOMException("Disconnected", "NetworkError");
  destination.fail.cleanup = new DOMException("Disconnected", "NetworkError");
  await assert.rejects(copyFile(destination, epub(), "new.epub"), (error) => {
    assert.match(error.cleanupMessage, /new.epub/);
    assert.equal(error.name, "NetworkError");
    return true;
  });
});

test("already cancelled import never creates a file", async () => {
  const { destination } = fakeDisk();
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    copyFile(destination, epub(), "new.epub", { signal: controller.signal }),
    { name: "AbortError" },
  );
  assert.deepEqual(destination.created, []);
});

test("serial reboot filters Playdate, sends only datadisk, and releases streams", async () => {
  let filter,
    options,
    command,
    closed = false;
  const port = {
    open: async (value) => {
      options = value;
    },
    writable: new WritableStream({
      write: async (chunk) => {
        command = new TextDecoder().decode(chunk);
      },
    }),
    readable: new ReadableStream(),
    close: async () => {
      closed = true;
    },
  };
  const serial = Object.assign(new EventTarget(), {
    requestPort: async (value) => {
      filter = value;
      return port;
    },
  });
  await requestDataDisk(serial);
  assert.deepEqual(filter.filters, [
    { usbVendorId: 0x1331, usbProductId: 0x5740 },
  ]);
  assert.equal(options.baudRate, 115200);
  assert.equal(command, "datadisk\n");
  assert.equal(closed, true);
  assert.equal(port.readable.locked, false);
  assert.equal(port.writable.locked, false);
});

test("a nonempty file appearing during create is left untouched", async () => {
  const { destination } = fakeDisk();
  const existing = new FakeFileHandle(
    "book.epub",
    new Blob(["other app’s book"]),
  );
  destination.getFileHandle = async () => existing;
  await assert.rejects(
    copyFile(destination, epub(), "book.epub"),
    /left untouched/,
  );
  assert.equal(await existing.blob.text(), "other app’s book");
  assert.deepEqual(destination.removed, []);
});

test("a changed entry is not deleted during failed-copy cleanup", async () => {
  const { destination } = fakeDisk();
  const existing = new FakeFileHandle(
    "book.epub",
    new Blob(["other app’s book"]),
  );
  destination.fail.afterWrite = () => {
    destination.entries.set("book.epub", existing);
    throw new Error("Entry changed");
  };
  await assert.rejects(copyFile(destination, epub(), "book.epub"), (error) => {
    assert.match(error.cleanupMessage, /unverified/);
    return true;
  });
  assert.deepEqual(destination.removed, []);
  assert.equal(await existing.blob.text(), "other app’s book");
});

test("verification cancellation removes only the unverified new copy", async () => {
  const { destination } = fakeDisk();
  const controller = new AbortController();
  await assert.rejects(
    copyFile(destination, epub(), "book.epub", {
      signal: controller.signal,
      onProgress: ({ phase }) => {
        if (phase === "verifying") controller.abort();
      },
    }),
    { name: "AbortError" },
  );
  assert.deepEqual(destination.removed, ["book.epub"]);
});

test("serial open failure is reported without sending a command", async () => {
  let closed = false;
  const serial = Object.assign(new EventTarget(), {
    requestPort: async () => ({
      open: async () => {
        throw new DOMException("Port busy", "NetworkError");
      },
      close: async () => {
        closed = true;
      },
    }),
  });
  await assert.rejects(requestDataDisk(serial), { name: "NetworkError" });
  assert.equal(closed, true);
});
