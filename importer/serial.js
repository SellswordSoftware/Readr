import { config } from "./config.js";

export async function requestDataDisk(serial) {
  const port = await serial.requestPort({
    filters: [
      { usbVendorId: config.usbVendorId, usbProductId: config.usbProductId },
    ],
  });
  let writer;
  let reader;
  let drain;
  let disconnected = false;
  const onDisconnect = (event) => {
    if (event.target === port || event.port === port) disconnected = true;
  };
  serial.addEventListener("disconnect", onDisconnect);
  try {
    await port.open({ baudRate: config.baudRate });
    // Drain console output so buffered logs cannot stall the serial connection.
    if (port.readable) {
      reader = port.readable.getReader();
      drain = (async () => {
        try {
          while (!(await reader.read()).done) {}
        } catch {
          /* Reboot ends the stream. */
        }
      })();
    }
    writer = port.writable.getWriter();
    try {
      await writer.write(new TextEncoder().encode("datadisk\n"));
    } catch (error) {
      if (!disconnected) throw error;
    }
  } finally {
    writer?.releaseLock();
    if (reader) {
      try {
        await reader.cancel();
      } catch {
        /* Reboot may close the port first. */
      }
      await drain;
      reader.releaseLock();
    }
    try {
      await port.close();
    } catch {
      /* Expected when the device reboots. */
    }
    serial.removeEventListener("disconnect", onDisconnect);
  }
}
