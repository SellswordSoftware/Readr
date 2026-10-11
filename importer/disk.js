import { config } from "./config.js";
import { isEpub, nameKey, nameError } from "./files.js?v=2";

export async function resolveDestination(root) {
  try {
    await root.getDirectoryHandle("Games", { create: false });
    const data = await root.getDirectoryHandle("Data", { create: false });
    try {
      const directory = await data.getDirectoryHandle(config.bundleId, {
        create: false,
      });
      return { root, directory };
    } catch (error) {
      if (error.name !== "NotFoundError") throw error;
      throw new Error(
        "readr’s data folder is missing. Install and open readr once, then reconnect your Playdate.",
      );
    }
  } catch (error) {
    if (error.name !== "NotFoundError" && error.name !== "TypeMismatchError")
      throw error;
    throw new Error(
      "Select the Playdate drive itself, with Games and Data inside it. Do not select a folder inside the drive.",
    );
  }
}

export async function listEntries(directory) {
  const entries = [];
  for await (const entry of directory.values())
    entries.push({ name: entry.name, kind: entry.kind });
  return entries;
}

function checkCancelled(signal) {
  if (signal?.aborted)
    throw new DOMException("Import cancelled.", "AbortError");
}

export async function copyFile(
  directory,
  file,
  name,
  {
    signal,
    onProgress = () => {},
    chunkBytes = config.chunkBytes,
    overwrite = false,
  } = {},
) {
  if (!file.size) throw new Error("This file is empty.");
  const invalid = nameError(name);
  if (invalid) throw new Error(invalid);
  if (!Number.isSafeInteger(chunkBytes) || chunkBytes < 1)
    throw new Error("Invalid copy chunk size.");
  checkCancelled(signal);
  const entries = await listEntries(directory);
  const existing = entries.find(
    (entry) => nameKey(entry.name) === nameKey(name),
  );
  if (existing && (!overwrite || existing.kind !== "file"))
    throw new Error(
      "This filename appeared on the drive. Select the drive again to review duplicates.",
    );
  if (
    !existing &&
    entries.filter((entry) => entry.kind === "file" && isEpub(entry.name))
      .length >= config.maxBooks
  )
    throw new Error("The library is full. No file was copied.");
  checkCancelled(signal);
  if (existing) name = existing.name;

  let handle;
  let writable;
  let owned = false;
  let committed = false;
  try {
    // The picker API has no exclusive-create operation. Recheck before creating,
    // and require users to keep other file managers out of this folder during import.
    handle = await directory.getFileHandle(name, { create: !existing });
    if (!existing && (await handle.getFile()).size !== 0)
      throw new Error(
        "A file appeared during import. It was left untouched; select the drive again.",
      );
    owned = !existing;
    writable = await handle.createWritable({
      keepExistingData: false,
      mode: "exclusive",
    });
    for (let offset = 0; offset < file.size; offset += chunkBytes) {
      checkCancelled(signal);
      const chunk = await file.slice(offset, offset + chunkBytes).arrayBuffer();
      checkCancelled(signal);
      await writable.write(chunk);
      onProgress({
        phase: "copying",
        bytes: Math.min(offset + chunk.byteLength, file.size),
        total: file.size,
      });
    }
    checkCancelled(signal);
    await writable.close();
    writable = null;
    committed = true;
    const copied = await handle.getFile();
    if (copied.size !== file.size)
      throw new Error("The copied file has a different size.");
    onProgress({ phase: "verifying", bytes: 0, total: file.size });
    for (let offset = 0; offset < file.size; offset += chunkBytes) {
      checkCancelled(signal);
      const [source, target] = await Promise.all([
        file.slice(offset, offset + chunkBytes).arrayBuffer(),
        copied.slice(offset, offset + chunkBytes).arrayBuffer(),
      ]);
      const a = new Uint8Array(source);
      const b = new Uint8Array(target);
      if (a.length !== b.length || a.some((value, index) => value !== b[index]))
        throw new Error("The copied bytes did not match the original.");
      onProgress({
        phase: "verifying",
        bytes: Math.min(offset + a.length, file.size),
        total: file.size,
      });
    }
    checkCancelled(signal);
  } catch (error) {
    if (writable) {
      try {
        await writable.abort();
      } catch {
        /* The drive may already be disconnected. */
      }
    }
    if (existing && committed) {
      error.cleanupMessage = `Check “${name}” on the drive: the replacement could not be verified. The previous book has already been overwritten.`;
    }
    if (owned) {
      try {
        const current = await directory.getFileHandle(name, { create: false });
        if (!(await current.isSameEntry(handle)))
          throw new Error("The entry changed.");
        await directory.removeEntry(name);
      } catch (cleanupError) {
        if (cleanupError.name !== "NotFoundError") {
          error.cleanupMessage = `Check “${name}” on the drive: an unverified file may remain. Remove that copy before retrying.`;
        }
      }
    }
    throw error;
  }
}

export function friendlyError(error) {
  switch (error.name) {
    case "AbortError":
      return "Cancelled. Completed books stay on the Playdate.";
    case "NotAllowedError":
    case "SecurityError":
      return "Permission was not granted. Try again and allow access to the Playdate drive.";
    case "QuotaExceededError":
      return "The drive may be full. Free some space, then select the drive again.";
    case "NotFoundError":
    case "NetworkError":
      return "The drive is no longer available. Reconnect it in Data Disk mode and select it again.";
    case "NoModificationAllowedError":
      return "The file could not be written. Check that the drive is writable and no other app is copying books.";
    default:
      return (
        error.message ||
        "The copy failed. Reconnect and select the drive again."
      );
  }
}
