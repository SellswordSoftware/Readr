import { config } from "./config.js";

export const nameKey = (name) => name.normalize("NFC").toLowerCase();
export const isEpub = (name) => /\.epub$/i.test(name);

export function nameError(name) {
  if (!isEpub(name)) return "Use a filename ending in .epub.";
  if (new TextEncoder().encode(name).length > config.maxNameBytes)
    return "Use a shorter filename (127 UTF-8 bytes maximum).";
  if (/[<>:"/\\|?*\u0000-\u001f\u007f]/u.test(name))
    return "Remove special characters such as /, \\, :, or ? from the filename.";
  if (/^[ .]|[ .]$/.test(name))
    return "The filename cannot start or end with a space or dot.";
  if (/^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)/i.test(name))
    return "Choose a filename that is not reserved by Windows.";
  return "";
}

export async function fileError(file) {
  if (!isEpub(file.name)) return "Choose an EPUB file.";
  if (file.size === 0) return "This file is empty.";
  const bytes = new Uint8Array(await file.slice(0, 4).arrayBuffer());
  if (
    bytes.length !== 4 ||
    bytes[0] !== 0x50 ||
    bytes[1] !== 0x4b ||
    bytes[2] !== 3 ||
    bytes[3] !== 4
  )
    return "This file does not look like an EPUB archive.";
  return "";
}

export function planQueue(items, entries, policy = "skip") {
  const used = new Map(entries.map((entry) => [nameKey(entry.name), entry]));
  let count = entries.filter(
    (entry) => entry.kind === "file" && isEpub(entry.name),
  ).length;
  return items.map((item) => {
    const row = {
      ...item,
      destination: item.name,
      status: "ready",
      message: "",
      overwrite: false,
    };
    const error = item.error || nameError(item.name);
    if (error) return { ...row, status: "invalid", message: error };
    if (used.has(nameKey(row.destination))) {
      if (policy === "skip")
        return {
          ...row,
          status: "skipped",
          message: "A file with this name already exists.",
        };
      if (policy === "overwrite") {
        const existing = used.get(nameKey(row.destination));
        if (existing.kind !== "file")
          return {
            ...row,
            status: "invalid",
            message: "A folder with this name exists. Choose another filename.",
          };
        row.destination = existing.name;
        row.overwrite = true;
        row.message = `Overwrite ${row.destination}`;
      } else {
        const stem = item.name.slice(0, -5);
        let number = 2;
        do {
          row.destination = `${stem} (${number++}).epub`;
        } while (used.has(nameKey(row.destination)));
        if (nameError(row.destination))
          return {
            ...row,
            status: "invalid",
            message: "Shorten the filename to leave room for a numbered copy.",
          };
        row.message = `Copy as ${row.destination}`;
      }
    }
    if (!row.overwrite && count >= config.maxBooks)
      return {
        ...row,
        status: "invalid",
        message: "readr’s library holds 255 books. This book does not fit.",
      };
    used.set(nameKey(row.destination), { name: row.destination, kind: "file" });
    if (!row.overwrite) count += 1;
    return row;
  });
}

export function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
}
