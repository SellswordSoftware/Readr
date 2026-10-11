import { fileError, formatBytes, planQueue } from "./files.js?v=2";
import {
  resolveDestination,
  listEntries,
  copyFile,
  friendlyError,
} from "./disk.js?v=2";
import { requestDataDisk } from "./serial.js";
import { config } from "./config.js";

const element = (id) => document.getElementById(id);
const state = {
  disk: null,
  entries: [],
  items: [],
  plan: [],
  busy: false,
  checking: false,
  finished: false,
  controller: null,
  nextId: 0,
};
const supported =
  window.isSecureContext &&
  typeof window.showDirectoryPicker === "function" &&
  typeof window.FileSystemFileHandle?.prototype.createWritable === "function";
const serialSupported = window.isSecureContext && !!navigator.serial;

function announce(message) {
  element("announcement").textContent = message;
}
function message(text, error = false) {
  element("connection-message").textContent = text;
  element("connection-message").classList.toggle("error", error);
}
function updateFlow() {
  const activeStep =
    state.controller || state.finished ? 3 : state.disk ? 2 : 1;
  for (let i = 1; i <= 3; i += 1) {
    const active = i === activeStep;
    if (active) element(`step-${i}`).setAttribute("aria-current", "step");
    else element(`step-${i}`).removeAttribute("aria-current");
    element(i === 3 ? "transfer" : `panel-${i}`).classList.toggle(
      "active-step",
      active,
    );
  }

  let action = null;
  if (supported && !state.busy && !state.checking) {
    action = state.finished
      ? "start-over"
      : state.disk
        ? element("import").disabled
          ? "choose-files"
          : "import"
        : !element("drive-picker").hidden
          ? "select-drive"
          : serialSupported
            ? "connect"
            : null;
  }
  for (const id of [
    "connect",
    "select-drive",
    "choose-files",
    "import",
    "start-over",
  ]) {
    element(id).classList.toggle("primary", id === action);
    element(id).classList.toggle("tonal", id !== action);
  }
}

function renderQueue() {
  if (!state.busy && !state.finished)
    state.plan = planQueue(
      state.items,
      state.entries,
      element("duplicate-policy").value,
    );
  element("queue").replaceChildren();
  for (const row of state.plan) {
    const li = document.createElement("li");
    const mark = document.createElement("span");
    mark.className = "file-mark";
    mark.textContent = row.status === "copied" ? "✓" : "▤";
    mark.setAttribute("aria-hidden", "true");
    const info = document.createElement("div");
    info.className = "file-info";
    const input = document.createElement("input");
    input.value = row.name;
    input.setAttribute(
      "aria-label",
      `Destination filename for ${row.file.name}`,
    );
    input.disabled = state.busy || state.checking || state.finished;
    input.spellcheck = false;
    input.addEventListener("change", () => {
      state.items.find((item) => item.id === row.id).name = input.value;
      renderQueue();
    });
    const meta = document.createElement("div");
    meta.className = `file-meta${["invalid", "failed"].includes(row.status) ? " error" : row.status === "copied" ? " success" : ""}`;
    const statusText = {
      ready: "Ready to copy",
      copied: "Copied and verified",
      copying: "Copying…",
      verifying: "Checking copied bytes…",
      skipped: "Skipped",
      cancelled: "Cancelled",
      failed: "Failed",
      invalid: "Not ready",
    }[row.status];
    meta.textContent = `${formatBytes(row.file.size)} · ${row.result || row.message || statusText}`;
    if (row.cleanupMessage) meta.textContent += ` ${row.cleanupMessage}`;
    info.append(input, meta);
    const remove = document.createElement("button");
    remove.className = "remove";
    remove.type = "button";
    remove.textContent = "×";
    remove.setAttribute("aria-label", `Remove ${row.name} from the list`);
    remove.disabled = state.busy || state.checking || state.finished;
    remove.addEventListener("click", () => {
      state.items = state.items.filter((item) => item.id !== row.id);
      renderQueue();
    });
    li.append(mark, info, remove);
    element("queue").append(li);
  }
  const ready = state.plan.filter((row) => row.status === "ready").length;
  element("book-count").textContent =
    `${state.items.length} ${state.items.length === 1 ? "book" : "books"}`;
  element("queue-tools").hidden = state.items.length === 0;
  element("drop-zone").hidden = state.busy;
  element("import").disabled =
    !state.disk || !ready || state.busy || state.checking || state.finished;
  element("choose-files").disabled =
    !state.disk || state.busy || state.checking;
  element("clear").disabled = state.busy || state.checking || state.finished;
  element("duplicate-policy").disabled =
    state.busy || state.checking || state.finished;
  element("queue-summary").textContent = state.finished
    ? "See the results below. Safely eject before opening readr."
    : state.busy
      ? "Keep your Playdate connected until copying and checking finish."
      : state.checking
        ? "Checking selected files…"
        : !state.disk
          ? "Select your Playdate drive to get started."
          : !state.items.length
            ? `${state.entries.filter((entry) => entry.kind === "file" && /\.epub$/i.test(entry.name)).length} books on your Playdate. Choose a few more.`
            : `${ready} ${ready === 1 ? "book" : "books"} ready to copy. ${state.plan.some((row) => row.status === "ready" && row.overwrite) ? "Matching books will be overwritten." : "Existing books stay untouched."}`;
  updateFlow();
}

function setBusy(value) {
  state.busy = value;
  element("connect").disabled =
    value || state.checking || state.finished || !serialSupported || !supported;
  element("manual").disabled =
    value || state.checking || state.finished || !supported;
  element("select-drive").disabled =
    value || state.checking || state.finished || !supported;
  element("start-over").disabled = value;
  renderQueue();
}

function setDisk(disk, entries = []) {
  state.disk = disk;
  state.entries = entries;
  element("drive-chip").textContent = disk ? "Drive selected" : "Not connected";
  element("drive-chip").classList.toggle("connected", !!disk);
  element("destination").hidden = !disk;
  element("destination").textContent = disk
    ? `Copying to ${disk.root.name}/Data/${config.bundleId}/`
    : "";
  renderQueue();
}

function showDrivePicker() {
  element("drive-picker").hidden = false;
  updateFlow();
  element("select-drive").focus();
}

element("manual").addEventListener("click", showDrivePicker);
element("connect").addEventListener("click", async () => {
  setBusy(true);
  message("Choose your unlocked Playdate in the browser’s connection dialog.");
  try {
    await requestDataDisk(navigator.serial);
    message(
      "Disk-mode request sent. Wait for the Playdate drive to appear, then select it below.",
    );
  } catch (error) {
    message(
      error.name === "NotFoundError"
        ? "No device selected. You can try again or enter Data Disk mode manually."
        : `Could not switch modes. ${friendlyError(error)} You can also use the manual instructions.`,
      true,
    );
    element("manual-details").open = true;
  } finally {
    setBusy(false);
    showDrivePicker();
  }
});

element("select-drive").addEventListener("click", async () => {
  // Open the picker before awaiting other work; it requires this click's activation.
  try {
    const selection = window.showDirectoryPicker({
      mode: "readwrite",
      id: "readr-playdate",
    });
    setBusy(true);
    setDisk(null);
    const root = await selection;
    const disk = await resolveDestination(root);
    const entries = await listEntries(disk.directory);
    setDisk(disk, entries);
    message(
      "Drive selected. Keep this folder free of other copying apps until you finish.",
    );
  } catch (error) {
    message(
      error.name === "AbortError"
        ? "No drive selected. Select it when you’re ready."
        : friendlyError(error),
      true,
    );
  } finally {
    setBusy(false);
    if (state.disk) element("choose-files").focus();
  }
});

async function addFiles(files) {
  if (!state.disk || state.busy || state.checking) return;
  state.checking = true;
  setBusy(false);
  try {
    for (const file of files) {
      let error;
      try {
        error = await fileError(file);
      } catch {
        error = "This file could not be read. Choose it again.";
      }
      state.items.push({ id: state.nextId++, file, name: file.name, error });
    }
    announce(
      `${files.length} ${files.length === 1 ? "file added" : "files added"}. Review the list before copying.`,
    );
  } finally {
    state.checking = false;
    setBusy(false);
    if (!element("import").disabled) element("import").focus();
  }
}

element("choose-files").addEventListener("click", () =>
  element("file-input").click(),
);
element("file-input").addEventListener("change", async (event) => {
  const files = Array.from(event.target.files);
  event.target.value = "";
  await addFiles(files);
});
for (const name of ["dragenter", "dragover"])
  element("drop-zone").addEventListener(name, (event) => {
    event.preventDefault();
    if (state.disk && !state.busy && !state.checking)
      element("drop-zone").classList.add("dragging");
  });
element("drop-zone").addEventListener("dragleave", (event) => {
  if (!element("drop-zone").contains(event.relatedTarget))
    element("drop-zone").classList.remove("dragging");
});
element("drop-zone").addEventListener("drop", async (event) => {
  event.preventDefault();
  element("drop-zone").classList.remove("dragging");
  await addFiles(Array.from(event.dataTransfer.files));
});
// Prevent dropped files outside the target from navigating away from an active copy.
window.addEventListener("dragover", (event) => event.preventDefault());
window.addEventListener("drop", (event) => event.preventDefault());
element("duplicate-policy").addEventListener("change", renderQueue);
element("clear").addEventListener("click", () => {
  state.items = [];
  renderQueue();
});

element("cancel").addEventListener("click", () => {
  state.controller?.abort();
  element("cancel").disabled = true;
  announce("Cancelling after the active disk operation finishes.");
});

async function runImport() {
  if (!state.disk || state.busy || state.checking) return;
  const disk = state.disk;
  const controller = new AbortController();
  state.controller = controller;
  setBusy(true);
  element("transfer").hidden = false;
  element("results").hidden = true;
  element("cancel").hidden = false;
  element("cancel").disabled = false;
  element("cancel").focus({ preventScroll: true });
  element("progress").value = 0;
  element("transfer").scrollIntoView({
    behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
      ? "instant"
      : "smooth",
    block: "nearest",
  });
  let failure = false;
  try {
    await resolveDestination(disk.root);
    state.entries = await listEntries(disk.directory);
    state.plan = planQueue(
      state.items,
      state.entries,
      element("duplicate-policy").value,
    );
    const pending = state.plan.filter((row) => row.status === "ready");
    for (const [index, row] of pending.entries()) {
      if (controller.signal.aborted || failure) {
        row.status = "cancelled";
        row.result = failure
          ? "Not copied. Reconnect and select the drive before retrying."
          : "Not copied.";
        continue;
      }
      row.status = "copying";
      renderQueue();
      announce(
        `Copying book ${index + 1} of ${pending.length}: ${row.destination}`,
      );
      try {
        await copyFile(disk.directory, row.file, row.destination, {
          signal: controller.signal,
          overwrite: row.overwrite,
          onProgress: (progress) => {
            if (row.status !== progress.phase) {
              row.status = progress.phase;
              renderQueue();
              announce(`Checking ${row.destination}.`);
            }
            element("transfer-label").textContent =
              `${index + 1} of ${pending.length} · ${row.destination}`;
            element("progress").value = progress.total
              ? (progress.bytes / progress.total) * 100
              : 0;
            element("progress-detail").textContent =
              `${progress.phase === "verifying" ? "Checking" : "Copying"} · ${formatBytes(progress.bytes)} of ${formatBytes(progress.total)}`;
          },
        });
        row.status = "copied";
        row.result = "Copied and verified";
      } catch (error) {
        row.status = controller.signal.aborted ? "cancelled" : "failed";
        row.result =
          error.name === "AbortError" && !controller.signal.aborted
            ? "The disk operation was interrupted. Select the drive again before retrying."
            : friendlyError(error);
        row.cleanupMessage = error.cleanupMessage;
        if (!controller.signal.aborted) failure = true;
      }
      renderQueue();
    }
  } catch (error) {
    failure = true;
    for (const row of state.plan)
      if (row.status === "ready") {
        row.status = "failed";
        row.result = friendlyError(error);
      }
    message(friendlyError(error), true);
  } finally {
    const counts = {
      copied: 0,
      skipped: 0,
      cancelled: 0,
      failed: 0,
      invalid: 0,
    };
    for (const row of state.plan)
      if (row.status in counts) counts[row.status] += 1;
    const summary = `${counts.copied} copied · ${counts.skipped} skipped · ${counts.cancelled} cancelled · ${counts.failed} failed · ${counts.invalid} not ready`;
    element("result-summary").textContent = summary;
    element("transfer-heading").textContent = failure
      ? "Copying stopped"
      : controller.signal.aborted
        ? "Import cancelled"
        : counts.copied
          ? "Your books are ready"
          : "No new books copied";
    element("transfer-label").textContent =
      "Completed copies have been checked against their originals.";
    element("progress-detail").textContent =
      "Eject the drive before disconnecting or leaving Data Disk mode.";
    element("cancel").hidden = true;
    element("results").hidden = false;
    announce(summary);
    // Keep the final rows until the user explicitly starts another session.
    state.disk = null;
    state.controller = null;
    state.finished = true;
    setBusy(false);
    element("import").disabled = true;
    element("start-over").disabled = false;
    element("drive-chip").textContent = "Ready to eject";
    element("drive-chip").classList.remove("connected");
    renderQueue();
    element("start-over").focus({ preventScroll: true });
  }
}

element("import").addEventListener("click", async () => {
  if (navigator.locks) {
    await navigator.locks.request(
      "readr-import",
      { ifAvailable: true },
      async (lock) => {
        if (!lock) {
          message("Another tab is importing books. Finish there first.", true);
          return;
        }
        await runImport();
      },
    );
  } else {
    await runImport();
  }
});
element("start-over").addEventListener("click", () => {
  state.finished = false;
  element("results").hidden = true;
  state.items = [];
  state.plan = [];
  element("transfer").hidden = true;
  element("transfer-heading").textContent = "A little closer to your next read";
  setDisk(null);
  setBusy(false);
  message("Select your Playdate drive again to start a new import.");
  showDrivePicker();
});
window.addEventListener("beforeunload", (event) => {
  if (state.busy) {
    event.preventDefault();
    event.returnValue = "";
  }
});

if (!supported) {
  element("capability").hidden = false;
  element("capability").textContent = window.isSecureContext
    ? "Browser-assisted copying needs desktop Chrome or Edge with local folder access. You can still use the manual copying instructions below."
    : "Open this page over HTTPS (or localhost for development) to enable browser-assisted copying. Manual instructions are below.";
  element("manual-details").open = true;
} else if (!serialSupported) {
  element("capability").hidden = false;
  element("capability").textContent =
    "This browser cannot switch your Playdate to Data Disk mode. Use the manual instructions, then select the drive to copy books.";
  element("manual-details").open = true;
}
setBusy(false);
