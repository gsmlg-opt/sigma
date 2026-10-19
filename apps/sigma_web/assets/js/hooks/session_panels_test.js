import { describe, expect, test } from 'bun:test'
import { SessionPanels, initialPanelState, panelVisible, changePanel, resizePanels } from './session_panels.js'

describe('responsive session panel navigation', () => {
  test('desktop defaults preserve both panels; narrow viewports keep content primary', () => {
    const state = initialPanelState()
    expect(panelVisible(state, 'navigation', 1440)).toBe(true)
    expect(panelVisible(state, 'details', 1440)).toBe(true)
    expect(panelVisible(state, 'navigation', 1024)).toBe(true)
    expect(panelVisible(state, 'details', 1024)).toBe(false)
    expect(panelVisible(state, 'navigation', 390)).toBe(false)
    expect(panelVisible(state, 'details', 390)).toBe(false)
  })
  test('opening the other drawer closes the first without changing desktop preference', () => {
    let state = changePanel(initialPanelState(), 'navigation', 390)
    expect(panelVisible(state, 'navigation', 390)).toBe(true)
    state = changePanel(state, 'details', 390)
    expect(panelVisible(state, 'navigation', 390)).toBe(false)
    expect(panelVisible(state, 'details', 390)).toBe(true)
    expect(state.navigation).toBe(true)
    expect(changePanel(state, 'details', 390).modal).toBe(null)
  })
  test('breakpoint transitions clear modal state and preserve desktop collapse', () => {
    let state = changePanel(initialPanelState(), 'details', 1440)
    expect(panelVisible(state, 'details', 1440)).toBe(false)
    state = resizePanels(state, 1440, 390)
    state = changePanel(state, 'details', 390)
    expect(state.modal).toBe('details')
    expect(resizePanels(state, 390, 420).modal).toBe('details')
    state = resizePanels(state, 420, 1440)
    expect(state.modal).toBe(null)
    expect(panelVisible(state, 'details', 1440)).toBe(false)
  })
  test('desktop navigation toggle dismisses an active medium-screen details drawer', () => {
    const state = changePanel(changePanel(initialPanelState(), 'details', 1024), 'navigation', 1024)
    expect(state.modal).toBe(null)
    expect(state.navigation).toBe(false)
  })
})

// Closing before the next paint must cancel both ordinary and Context-entry focus.
test('close cancels pending focus frames before restoring the opener', () => {
  const original = globalThis.window
  const cancelled = []
  globalThis.window = { cancelAnimationFrame: id => cancelled.push(id) }
  try {
    const hook = {
      ...SessionPanels,
      _panelFrame: 11, _contextFrame: 12,
      _panelState: { ...initialPanelState(), modal: 'details' },
      _applyPanels(previous) {
        expect(previous).toBe('details')
        expect(this._panelState.modal).toBe(null)
        expect(cancelled).toEqual([11, 12])
      }
    }
    hook._closePanel()
    expect(hook._panelFrame).toBe(null)
    expect(hook._contextFrame).toBe(null)
  } finally {
    if (original === undefined) delete globalThis.window
    else globalThis.window = original
  }
})

for (const width of [390, 1440]) {
  test(`subagent entry opens and focuses the roster at ${width}px without toggling it closed`, async () => {
    const previousWindow = globalThis.window
    const previousDocument = globalThis.document
    const frames = new Map()
    let nextFrame = 0
    const focused = []
    const roster = {
      tagName: 'DETAILS', open: false,
      scrollIntoView: options => expect(options).toEqual({ block: 'nearest' }),
      focus: options => focused.push(options)
    }
    const target = {
      dataset: { sessionPanelToggle: 'details' },
      matches: () => true,
      hasAttribute: name => name === 'data-session-subagents-open'
    }
    const el = {
      addEventListener() {}, removeEventListener() {},
      querySelector(selector) {
        expect(selector).toBe('#session-subagents')
        return roster
      }
    }
    globalThis.window = {
      innerWidth: width, addEventListener() {}, removeEventListener() {},
      requestAnimationFrame(callback) { frames.set(++nextFrame, callback); return nextFrame },
      cancelAnimationFrame(id) { frames.delete(id) }
    }
    globalThis.document = { addEventListener() {}, removeEventListener() {} }
    const hook = { ...SessionPanels, el, _applyPanels() {} }
    try {
      hook.mounted()
      // Start with the desktop rail collapsed too: entry must force it open.
      hook._panelState.details = false
      await hook._panelClick({ composedPath: () => [target] })
      for (const callback of [...frames.values()]) callback()
      expect(panelVisible(hook._panelState, 'details', width)).toBe(true)
      expect(roster.open).toBe(true)
      expect(focused).toEqual([{ preventScroll: true }])
      await hook._panelClick({ composedPath: () => [target] })
      expect(panelVisible(hook._panelState, 'details', width)).toBe(true)
      expect(hook._panelState.modal).toBe(width < 1280 ? 'details' : null)
      hook.destroyed()
    } finally {
      if (previousWindow === undefined) delete globalThis.window
      else globalThis.window = previousWindow
      if (previousDocument === undefined) delete globalThis.document
      else globalThis.document = previousDocument
    }
  })
}
