import { expect, mock, test } from "bun:test"
import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"

// Exercise the message renderer registered with the chat bridge.
mock.module("phoenix_duskmoon/react-chat", () => ({
  createDuskmoonReactChat: (options) => options,
  useChatSubmission: () => ({})
}))
const { SigmaReactChat } = await import("./session_chat.js")

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
