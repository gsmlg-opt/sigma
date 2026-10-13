import React, { useEffect, useLayoutEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { Chat } from "@duskmoon-dev/components/chat"
import { Markdown } from "@duskmoon-dev/components/markdown"
import { Button } from "@duskmoon-dev/components/button"
import { createDuskmoonReactChat, useChatSubmission } from "phoenix_duskmoon/react-chat"
import { encodeImageFiles, validateImageFiles } from "../chat_attachments.js"
import { filterSkillCandidates, insertSkillCandidate, searchableRemoteSources } from "../skill_completion.js"

const h = React.createElement
const attachmentDrafts = new Map()
const attachmentErrors = { slash_command: "Images cannot be combined with slash commands.", too_many: "Attach no more than four images.", too_large: "Each image must be at most 5 MiB; total at most 10 MiB.", unsupported_type: "Attach PNG, JPEG, GIF or WebP images." }

function Attachment({ file, remove, disabled }) {
  const [url, setUrl] = useState(null)
  useEffect(() => {
    const url = URL.createObjectURL(file)
    setUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [file])
  return h("div", { className: "flex items-center gap-2" },
    url && h("img", { src: url, alt: file.name, className: "h-12 w-12 rounded object-contain" }),
    h("span", null, file.name),
    h(Button, { type: "button", appearance: "ghost", disabled, onClick: remove, "aria-label": `Remove ${file.name}` }, "Remove"))
}

function Composer(props) {
  const { metadata, bridge, active, connected, synchronizing, canSubmit } = props
  const key = metadata.draftKey
  const [value, setValue] = useState("")
  const [files, setFiles] = useState([])
  const [remote, setRemote] = useState([])
  const [error, setError] = useState("")
  const { submit, busy, notice } = useChatSubmission(props)
  useEffect(() => {
    if (key) {
      setValue(window.sessionStorage.getItem(key) || "")
      setFiles(attachmentDrafts.get(key) || [])
    }
  }, [key])
  function changeValue(next) {
    setValue(next)
    if (key) {
      if (next) window.sessionStorage.setItem(key, next)
      else window.sessionStorage.removeItem(key)
    }
  }
  function changeFiles(next) {
    setFiles(next)
    if (key) {
      if (next.length) attachmentDrafts.set(key, next)
      else attachmentDrafts.delete(key)
    }
  }
  function addFiles(incoming) {
    const next = [...files, ...incoming]
    const code = validateImageFiles(next)
    if (code) setError(attachmentErrors[code])
    else { setError(""); changeFiles(next) }
  }
  const skillQuery = value.startsWith("/skill ") ? value.slice(7).split(/\s/, 1)[0] : null
  useEffect(() => {
    setRemote([])
    if (skillQuery === null || !metadata.remoteSkillsUrl) return
    const controller = new AbortController()
    const timer = setTimeout(async () => {
      try {
        const pages = await Promise.all(searchableRemoteSources(metadata.remoteSources).map(async (source) => {
          const url = new URL(metadata.remoteSkillsUrl, window.location.origin)
          url.searchParams.set("sourceId", source.sourceId || source.source_id)
          url.searchParams.set("q", skillQuery)
          url.searchParams.set("limit", "50")
          const response = await fetch(url, { signal: controller.signal, headers: { accept: "application/json" } })
          if (!response.ok) return []
          const body = await response.json()
          return (body.items || []).map((item) => ({
            kind: "skill", reference: item.reference, name: item.name, label: item.name,
            description: item.description, source: item.sourceId
          }))
        }))
        if (!controller.signal.aborted) setRemote(pages.flat())
      } catch (error) {
        if (error.name !== "AbortError") setRemote([])
      }
    }, 200)
    return () => { clearTimeout(timer); controller.abort() }
  }, [skillQuery, metadata.remoteSkillsUrl, metadata.remoteSources])
  const commands = metadata.commands || []
  const candidates = skillQuery !== null
    ? filterSkillCandidates([...commands, ...remote], value)
    : value.startsWith("/") && !/\s/.test(value)
      ? commands.filter((command) => command.value?.toLowerCase().startsWith(value.toLowerCase())) : []
  const completion = candidates.length ? {
    items: candidates.map((candidate, index) => ({
      id: String(index), label: candidate.label || candidate.name || candidate.value,
      description: [candidate.description, candidate.source].filter(Boolean).join(" · ")
    })),
    onSelect: (item) => {
      const candidate = candidates[Number(item.id)]
      changeValue(skillQuery !== null ? insertSkillCandidate(value, candidate) : `${candidate.value} `)
    }
  } : undefined

  const host = document.getElementById("chat-input-area")
  if (!host) return null
  return createPortal(h(React.Fragment, null,
    active && h(Chat.Status, { role: "status" }, h(Chat.StatusItem, null, props.runtime.label)),
    h(Chat.Composer, {
      id: "prompt-input", value, onValueChange: changeValue,
      attachments: files, onAttachmentsChange: changeFiles, renderAttachment: (file, context) => h(Attachment, { file, ...context }),
      accept: "image/png,image/jpeg,image/gif,image/webp", allowAttachmentOnly: true,
      generating: active, canSubmit, busy, disabled: !connected || synchronizing, error: error || notice || undefined,
      completion, minRows: 1, maxRows: 6,
      textareaProps: {
        placeholder: "Ask ∑ anything…", "aria-label": "Message",
        onPaste: (event) => {
          const images = Array.from(event.clipboardData.files).filter((file) => file.type.startsWith("image/"))
          if (images.length) { event.preventDefault(); addFiles(images) }
        }
      },
      onDragOver: (event) => {
        if (Array.from(event.dataTransfer.types).includes("Files")) event.preventDefault()
      },
      onDrop: (event) => {
        if (event.dataTransfer.files.length) {
          event.preventDefault()
          if (connected && !synchronizing) addFiles(Array.from(event.dataTransfer.files))
        }
      },
      onStop: () => bridge.send("stop", {}).catch((error) => setError(error.message)),
      onSubmitError: (error) => setError(error.message),
      onSubmit: async ({ value, files }) => {
        setError("")
        const code = files.length && value.trim().startsWith("/") ? "slash_command" : validateImageFiles(files)
        if (code) {
          setError(attachmentErrors[code])
          return false
        }
        const result = await encodeImageFiles(files)
        if (!result.ok) { setError("Could not read the attached images."); return false }
        try { await submit({ text: value, images: result.images }); return true }
        catch { return false }
      },
      children: (!connected || synchronizing) && h("span", { role: "status" }, "Draft preserved")
    })
  ), host)
}

// This HTML comes only from Sigma's escaped observability components, never model HTML.
function Metrics({ html }) {
  const ref = useRef(null)
  const opened = useRef(new Set())
  useLayoutEffect(() => {
    ref.current.querySelectorAll("details[id]").forEach((el) => { el.open = opened.current.has(el.id) })
  }, [html])
  return h("div", {
    ref, dangerouslySetInnerHTML: { __html: html },
    onToggleCapture: (event) => {
      const el = event.target
      if (!el.id) return
      el.open ? opened.current.add(el.id) : opened.current.delete(el.id)
    }
  })
}

function Message({ message, bridge, targetId, timeline, active, connected, synchronizing, admission }) {
  const [notice, setNotice] = useState("")
  const metadata = message.metadata || {}
  return h(Chat, { id: targetId, timeline, role: "article", placement: "start", className: "sigma-chat-with-actions mx-auto w-full max-w-4xl", "data-message-id": message.id },
    h(Chat.Header, null, message.author, " · ", h("time", { dateTime: new Date(metadata.timestamp).toISOString() }, new Date(metadata.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false }))),
    h(Chat.Bubble, { streaming: message.status === "streaming", color: message.role === "user" ? "secondary" : undefined },
      metadata.reasoning && h(Chat.Reasoning, null, h("summary", null, "Reasoning"), metadata.reasoning),
      ...(message.tools || []).map((tool) => h(Chat.Tool, { key: tool.id, status: tool.status },
        h(Chat.ToolHeader, null, tool.name, ": ", tool.status),
        h(Chat.ToolCall, null, h("pre", { className: "overflow-x-auto whitespace-pre-wrap text-xs" }, tool.input)),
        tool.result != null && h(Chat.ToolResult, null, h("pre", { className: "overflow-x-auto whitespace-pre-wrap text-xs" }, tool.result)))),
      message.content && h(Markdown, { markdown: message.content, className: "chat-bubble-content" }),
      ...(metadata.images || []).map((src, index) => h("img", { key: index, src, alt: "Attached image", loading: "lazy", className: "max-h-96 max-w-full rounded object-contain" }))),
    h(Chat.Footer, null,
      metadata.footerHtml && h(Metrics, { html: metadata.footerHtml }),
      h(Chat.Actions, null,
        h(Button, { type: "button", appearance: "ghost", onClick: () => navigator.clipboard.writeText(message.content || "").then(() => setNotice("Copied")).catch(() => setNotice("Copy failed")) }, "Copy"),
        ...(message.actions || []).map((action) => h(Button, {
          key: action.id, id: action.domId, type: "button", appearance: "ghost",
          disabled: !connected || synchronizing || admission.canSubmit === false || active,
          onClick: () => bridge.send("action", { message_id: message.id, action: action.id }).catch((error) => setNotice(error.message))
        }, action.label))),
      message.role === "user" && h("details", { className: "text-xs text-on-surface-variant" },
        h("summary", null, "What Resend does"), "Starts a new turn with this message. Earlier file edits, commands, Git changes, and external requests remain."),
      h("span", { role: "status" }, notice)))
}

const chat = createDuskmoonReactChat({ Composer, renderMessage: Message })
export const SigmaReactChat = {
  ...chat,
  mounted() {
    document.getElementById("chat-input-area")?.replaceChildren()
    chat.mounted.call(this)
  }
}
