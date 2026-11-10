import React, { useEffect, useLayoutEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { Chat } from "@duskmoon-dev/components/chat"
import { Markdown } from "@duskmoon-dev/components/markdown"
import { Button } from "@duskmoon-dev/components/button"
import { Typography } from "@duskmoon-dev/components/typography"
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
      completion, minRows: 1, maxRows: 6, compact: true,
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

const PREVIEW_LINES = 4
const RESEND_HINT = "Starts a new turn with this message. Earlier file edits, commands, Git changes, and external requests remain."
// Terminal colour/control sequences are display noise in the transcript.
// eslint-disable-next-line no-control-regex
const ANSI = /\u001b\[[0-9;?]*[A-Za-z]/g
const pre = (key, text) => h("pre", { key, className: "sigma-tool-pre" }, text)

// Codex-style tool row: one summary line ("Ran git status") with a short output
// preview, and the full input/output inside the native Chat.Tool disclosure.
function toolBlock(tool) {
  const raw = tool.output ?? tool.result
  const output = raw && raw.replace(ANSI, "")
  const lines = output ? output.replace(/\s+$/, "").split("\n") : []
  const exitFailed = tool.exitCode != null && tool.exitCode !== 0
  const state = tool.status === "running" ? "running…"
    : tool.status === "pending" ? tool.statusLabel
      : tool.status === "error" ? "failed"
        : exitFailed ? `exit ${tool.exitCode}` : null
  return h(React.Fragment, { key: `tool:${tool.id}` },
    h(Chat.Tool, { status: exitFailed ? "error" : tool.status, className: "sigma-tool" },
      h(Chat.ToolHeader, null,
        h("span", { className: "sigma-tool-title" }, tool.title || tool.name),
        tool.detail && h("code", { className: "sigma-tool-detail" }, tool.detail),
        state && h(Chat.ToolStatus, null, state)),
      tool.input && h(Chat.ToolCall, null, pre("input", tool.input)),
      (lines.length > 0 || tool.images?.length > 0) && h(Chat.ToolResult, null,
        lines.length > 0 && pre("output", output),
        ...(tool.images || []).map((src, index) => h("img", {
          key: index, src, alt: `${tool.name} result ${index + 1}`, loading: "lazy",
          className: "max-h-96 max-w-full rounded object-contain"
        })))),
    tool.plan && h("ol", { className: "sigma-plan" }, ...tool.plan.map((item, index) =>
      h("li", { key: index, "data-status": item.status }, item.step))),
    lines.length > 0 && !tool.plan && h("pre", { className: "sigma-tool-preview", "aria-hidden": true },
      lines.slice(0, PREVIEW_LINES).join("\n") + (lines.length > PREVIEW_LINES ? `\n… +${lines.length - PREVIEW_LINES} lines` : "")))
}

function renderBlock(block) {
  if (block.type === "tool") return toolBlock(block)
  if (block.type === "reasoning")
    return h(Chat.Reasoning, { key: `reasoning:${block.id}` }, h("summary", null, "Thinking"), block.text)
  return h(Markdown, { key: `text:${block.id}`, markdown: block.text, className: "chat-bubble-content" })
}

// Work (thinking, tool calls and the narration between them) collapses into one
// Chat.Work disclosure; the final answer stays outside it, as Codex shows a turn.
function splitWork(blocks) {
  let last = -1
  blocks.forEach((block, index) => { if (block.type !== "text") last = index })
  return { work: blocks.slice(0, last + 1), answer: blocks.slice(last + 1) }
}

function workSummary(work, running) {
  const tools = work.filter((block) => block.type === "tool").length
  if (running) return "Working…"
  return tools ? `Worked · ${tools} tool call${tools === 1 ? "" : "s"}` : "Thought"
}

function Sources({ sources }) {
  return sources?.length > 0 && h("nav", { "aria-label": "Sources", className: "mt-2 text-sm" },
    h("span", null, "Sources"),
    h("ol", { className: "list-inside list-decimal" }, ...sources.map((source) =>
      h("li", { key: source.url }, h(Typography.Link, { href: source.url, target: "_blank", rel: "noopener noreferrer", className: "break-words" }, source.title)))))
}

function Actions({ message, bridge, active, connected, synchronizing, admission, setNotice }) {
  const time = new Date(message.metadata?.timestamp)
  return h(Chat.Actions, { hover: true, className: "sigma-message-actions" },
    h("time", { dateTime: time.toISOString(), className: "sigma-message-time" }, time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false })),
    h(Button, { type: "button", appearance: "ghost", onClick: () => navigator.clipboard.writeText(message.content || "").then(() => setNotice("Copied")).catch(() => setNotice("Copy failed")) }, "Copy"),
    ...(message.actions || []).map((action) => h(Button, {
      key: action.id, id: action.domId, type: "button", appearance: "ghost",
      title: action.id === "retry_message" ? RESEND_HINT : undefined,
      disabled: !connected || synchronizing || admission.canSubmit === false || active,
      onClick: () => bridge.send("action", { message_id: action.messageId || message.id, action: action.id }).catch((error) => setNotice(error.message))
    }, action.label)))
}

function Message(props) {
  const { message, targetId, timeline } = props
  const [notice, setNotice] = useState("")
  const metadata = message.metadata || {}
  const images = (metadata.images || []).map((src, index) => h("img", { key: `image:${index}`, src, alt: "Attached image", loading: "lazy", className: "max-h-96 max-w-full rounded object-contain" }))
  const footer = [
    metadata.footerHtml && h(Metrics, { key: "metrics", html: metadata.footerHtml }),
    h(Actions, { key: "actions", ...props, setNotice }),
    h("span", { key: "notice", role: "status" }, notice)
  ]

  if (message.role === "user") {
    return h(Chat, { id: targetId, placement: "end", role: "article", className: "sigma-chat-user mx-auto w-full max-w-4xl", "data-message-id": message.id },
      h(Chat.Bubble, { color: "secondary", collapsible: true },
        message.content && h(Markdown, { markdown: message.content, className: "chat-bubble-content" }), ...images),
      h(Chat.Footer, null, ...footer))
  }

  const blocks = Array.isArray(message.blocks) && message.blocks.length ? message.blocks
    : message.content ? [{ type: "text", id: "content", text: message.content }] : []
  const { work, answer } = splitWork(blocks)
  const running = message.status === "streaming" || message.turnStatus === "running" ||
    work.some((block) => block.type === "tool" && block.status === "running")
  return h(Chat.Agent, { id: targetId, timeline, role: "article", className: "sigma-chat-agent mx-auto w-full max-w-4xl", "data-message-id": message.id },
    message.role !== "assistant" && h("div", { className: "sigma-message-role" }, message.author),
    work.length > 0 && h(Chat.Work, { open: running },
      h(Chat.WorkSummary, null, workSummary(work, running)),
      h(Chat.WorkBody, null, ...work.map(renderBlock))),
    answer.length > 0 && h(Chat.Content, { streaming: message.status === "streaming" }, ...answer.map(renderBlock)),
    images.length > 0 && h("div", null, ...images),
    h(Sources, { sources: metadata.sources }),
    ...footer)
}

const chat = createDuskmoonReactChat({ Composer, renderMessage: Message })
export const SigmaReactChat = {
  ...chat,
  mounted() {
    document.getElementById("chat-input-area")?.replaceChildren()
    chat.mounted.call(this)
  }
}
