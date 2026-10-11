export class FakeDirectory {
  constructor(name = "Playdate", entries = []) {
    this.name = name;
    this.kind = "directory";
    this.entries = new Map(entries.map((entry) => [entry.name, entry]));
    this.created = [];
    this.removed = [];
    this.fail = {};
  }
  async *values() {
    yield* this.entries.values();
  }
  async getDirectoryHandle(name, options = {}) {
    const entry = this.entries.get(name);
    if (!entry) throw new DOMException("Missing directory", "NotFoundError");
    if (entry.kind !== "directory")
      throw new DOMException("Not a directory", "TypeMismatchError");
    if (options.create) throw new Error("Directory creation is forbidden.");
    return entry;
  }
  async getFileHandle(name, options = {}) {
    if (this.fail.lookup) throw this.fail.lookup;
    let entry = this.entries.get(name);
    if (!entry) {
      if (!options.create)
        throw new DOMException("Missing file", "NotFoundError");
      entry = new FakeFileHandle(name, new Blob(), this.fail);
      this.entries.set(name, entry);
      this.created.push(name);
    }
    if (entry.kind !== "file")
      throw new DOMException("Not a file", "TypeMismatchError");
    return entry;
  }
  async removeEntry(name) {
    if (this.fail.cleanup) throw this.fail.cleanup;
    this.removed.push(name);
    this.entries.delete(name);
  }
}

export class FakeFileHandle {
  constructor(name, blob = new Blob(), fail = {}) {
    this.name = name;
    this.kind = "file";
    this.blob = blob;
    this.fail = fail;
    this.writes = [];
    this.closed = false;
    this.aborted = false;
  }
  async isSameEntry(other) {
    return this === other;
  }
  async getFile() {
    return this.blob;
  }
  async createWritable() {
    if (this.fail.open) throw this.fail.open;
    const chunks = [];
    return {
      write: async (chunk) => {
        if (this.fail.write) throw this.fail.write;
        this.writes.push(chunk.byteLength);
        chunks.push(chunk);
        await this.fail.afterWrite?.();
      },
      close: async () => {
        if (this.fail.close) throw this.fail.close;
        this.closed = true;
        this.blob = this.fail.corrupt
          ? new Blob([new Uint8Array([0, 0, 0, 0])])
          : new Blob(chunks);
      },
      abort: async () => {
        this.aborted = true;
      },
    };
  }
}

export function fakeDisk() {
  const destination = new FakeDirectory("com.sellswordsoftware.readr");
  const root = new FakeDirectory("Playdate", [
    new FakeDirectory("Games"),
    new FakeDirectory("Data", [destination]),
  ]);
  return { root, destination };
}

export const epub = (
  name = "book.epub",
  bytes = [0x50, 0x4b, 3, 4, 1, 2, 3, 4, 5],
) => new File([new Uint8Array(bytes)], name);
