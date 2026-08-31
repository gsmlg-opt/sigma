const MAX_FILES = 4
const MAX_FILE_SIZE = 5 * 1024 * 1024
const MAX_TOTAL_SIZE = 10 * 1024 * 1024
const ALLOWED_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"])

export function validateImageFiles(files) {
  const imageFiles = Array.from(files || [])

  if (imageFiles.length > MAX_FILES) return "too_many"
  if (imageFiles.some((file) => !ALLOWED_TYPES.has(file.type))) return "unsupported_type"
  if (imageFiles.some((file) => file.size > MAX_FILE_SIZE)) return "too_large"
  if (imageFiles.reduce((total, file) => total + file.size, 0) > MAX_TOTAL_SIZE) return "too_large"

  return null
}

function readFileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(reader.error)
    reader.onabort = () => reject(new Error("read aborted"))
    reader.readAsDataURL(file)
  })
}

export async function encodeImageFiles(files, read = readFileAsDataUrl) {
  const validationError = validateImageFiles(files)
  if (validationError) return { ok: false, code: validationError }

  try {
    const images = await Promise.all(Array.from(files || []).map(async (file) => {
      const dataUrl = await read(file)
      const prefix = `data:${file.type};base64,`

      if (typeof dataUrl !== "string" || !dataUrl.startsWith(prefix)) throw new Error("invalid data URL")

      return { data: dataUrl.slice(prefix.length), mime_type: file.type }
    }))

    return { ok: true, images }
  } catch (_error) {
    return { ok: false, code: "read_failed" }
  }
}
