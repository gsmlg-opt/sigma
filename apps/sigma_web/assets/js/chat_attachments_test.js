import { describe, expect, test } from "bun:test"

import { encodeImageFiles, validateImageFiles } from "./chat_attachments.js"

const file = (type, size = 1) => ({ name: `${type}.image`, type, size })

describe("validateImageFiles", () => {
  test("accepts no file collection", () => {
    expect(validateImageFiles(null)).toBeNull()
  })

  test("rejects more than four files", () => {
    expect(validateImageFiles(Array.from({ length: 5 }, () => file("image/png")))).toBe("too_many")
  })

  test("rejects unsupported MIME types, including SVG", () => {
    expect(validateImageFiles([file("image/svg+xml")])).toBe("unsupported_type")
    expect(validateImageFiles([file("application/pdf")])).toBe("unsupported_type")
  })

  test("rejects an individual file larger than 5 MiB", () => {
    expect(validateImageFiles([file("image/png", 5 * 1024 * 1024 + 1)])).toBe("too_large")
  })

  test("rejects an aggregate larger than 10 MiB", () => {
    expect(validateImageFiles(Array.from({ length: 3 }, () => file("image/png", 4 * 1024 * 1024)))).toBe("too_large")
  })
})

describe("encodeImageFiles", () => {
  test("encodes an undefined file collection as empty", async () => {
    expect(await encodeImageFiles(undefined)).toEqual({ ok: true, images: [] })
  })

  test("encodes data URLs into image payloads", async () => {
    const files = [file("image/png"), file("image/jpeg")]
    const read = async (currentFile) => `data:${currentFile.type};base64,Zm9v`

    expect(await encodeImageFiles(files, read)).toEqual({
      ok: true,
      images: [
        { data: "Zm9v", mime_type: "image/png" },
        { data: "Zm9v", mime_type: "image/jpeg" }
      ]
    })
  })

  test("returns read_failed when the reader fails", async () => {
    expect(await encodeImageFiles([file("image/png")], async () => {
      throw new Error("unable to read")
    })).toEqual({ ok: false, code: "read_failed" })
  })

  test("returns read_failed for a malformed data URL", async () => {
    expect(await encodeImageFiles([file("image/png")], async () => "not-a-data-url")).toEqual({
      ok: false,
      code: "read_failed"
    })
  })

  test("returns read_failed when the default reader is aborted", async () => {
    const originalFileReader = globalThis.FileReader

    globalThis.FileReader = class {
      readAsDataURL() {
        if (this.onabort) this.onabort()
      }
    }

    try {
      expect(await encodeImageFiles([file("image/png")])).toEqual({ ok: false, code: "read_failed" })
    } finally {
      globalThis.FileReader = originalFileReader
    }
  }, { timeout: 100 })
})
