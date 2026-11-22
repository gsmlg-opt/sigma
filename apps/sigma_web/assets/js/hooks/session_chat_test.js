import { expect, mock, test } from "bun:test"
import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"

// Exercise the message renderer registered with the chat bridge.
mock.module("duskmoon_phoenix/react-chat", () => ({
  createDuskmoonReactChat: (options) => options,
  useChatSubmission: () => ({})
}))
const { SigmaReactChat } = await import("./session_chat.js")

test("the session transcript resumes following after scrolling back to the bottom", () => {
  expect(SigmaReactChat.resumeFollowOnScroll).toBe(true)
})

for (const [turnStatus, workLabel, detailsLabel] of [
  ["running", "Working… · 1 tool call", "Turn details"],
  ["failed", "Worked · 1 tool call", "Turn failed · details"]
]) {
  test(`the ${turnStatus} turn keeps command output and metrics inside closed disclosures`, async () => {
    const message = {
      id: "assistant", role: "assistant", turnStatus,
      blocks: [
        { type: "tool", id: "call", title: "Ran", detail: "mix test", status: "error", exitCode: 1, output: "test failed\nmore output" },
        { type: "text", id: "answer", text: "The test failed." }
      ],
      metadata: { timestamp: 1000, footerHtml: "<span>Turn metrics</span>" }
    }
    const markup = renderToStaticMarkup(createElement(SigmaReactChat.renderMessage, { message, admission: {} }))
    const labels = {}
    const rewriter = new HTMLRewriter()
    for (const [key, selector] of Object.entries({
      work: "details.chat-work:not([open]) > summary",
      badge: ".chat-work-body > details:not([open]) > summary .chat-tool-status",
      output: ".chat-tool .chat-tool-result pre",
      answer: "[role=article] > .chat-content",
      details: "details.sigma-turn-details:not([open]) > summary",
      metrics: ".sigma-turn-details span"
    })) {
      rewriter.on(selector, { text(chunk) { labels[key] = (labels[key] || "") + chunk.text } })
    }
    await rewriter.transform(new Response(markup)).text()

    expect(labels).toEqual({
      work: workLabel, badge: "exit 1", output: "test failed\nmore output",
      answer: "The test failed.", details: detailsLabel, metrics: "Turn metrics"
    })
    expect(markup.match(/more output/g)).toHaveLength(1)
  })
}

for (const [role, actions, expected] of [
  ["user", [["edit_message", "Edit"], ["fork_at", "Fork"], ["prepare_retry", "Retry"]], ["Copy", "Edit", "Fork", "Retry"]],
  ["assistant", [["fork_at", "Fork"], ["continue_session", "Continue"]], ["Copy", "Fork", "Continue"]]
]) {
  test(`${role} actions are labeled icon buttons in order`, async () => {
    const message = {
      id: "item", role, content: "message", metadata: { timestamp: 1000 },
      actions: actions.map(([id, label]) => ({ id, label }))
    }
    const markup = renderToStaticMarkup(createElement(SigmaReactChat.renderMessage, {
      message, connected: true, admission: {}
    }))
    const labels = []
    const icons = []
    const visibleText = []
    const rewriter = new HTMLRewriter()
      .on(".sigma-message-actions button", {
        element(el) {
          labels.push(el.getAttribute("aria-label"))
          expect(el.getAttribute("title")).toBeTruthy()
        },
        text(chunk) { if (chunk.text.trim()) visibleText.push(chunk.text) }
      })
      .on(".sigma-message-actions button svg[aria-hidden=true] use", {
        element(el) { icons.push(el.getAttribute("href")) }
      })
    await rewriter.transform(new Response(markup)).text()
    expect(labels).toEqual(expected)
    expect(new Set(icons).size).toBe(expected.length)
    expect(visibleText).toEqual([])
  })
}
