const widths = { navigation: 768, details: 1280 }

export function initialPanelState() {
  return { navigation: true, details: true, modal: null }
}

export function panelVisible(state, panel, width) {
  return width >= widths[panel] ? state[panel] : state.modal === panel
}

export function changePanel(state, panel, width) {
  if (!(panel in widths)) return state
  if (width >= widths[panel]) return { ...state, [panel]: !state[panel], modal: null }
  return { ...state, modal: state.modal === panel ? null : panel }
}

export function resizePanels(state, before, after) {
  const crossed = Object.values(widths).some(limit => (before < limit) !== (after < limit))
  return crossed ? { ...state, modal: null } : state
}

function activeElement() {
  let active = document.activeElement
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement
  return active
}

// Follow the composed tree so DuskMoon's shadow buttons participate in Tab order.
function focusableElements(root) {
  const found = new Set()
  const visit = element => {
    if (element.nodeType !== 1 || element.hidden || element.inert) return
    if (element.matches('button, a[href], input, select, textarea, summary, [tabindex]') &&
        element.tabIndex >= 0 && !element.disabled && element.getClientRects().length > 0) {
      found.add(element)
    }
    const children = element.tagName === 'SLOT'
      ? element.assignedElements({ flatten: true })
      : (element.shadowRoot || element).children
    for (const child of children) visit(child)
  }
  visit(root)
  return [...found]
}

export const SessionPanels = {
  mounted() {
    this._panelState = initialPanelState()
    this._panelWidth = window.innerWidth
    this._inertElements = new Map()
    this._opener = null
    this._panelClick = async event => {
      const target = event.composedPath().find(node => node?.matches?.('[data-session-panel-toggle], [data-session-panel-close], [data-session-panel-backdrop], [data-session-copy]'))
      if (!target) return
      if (target.hasAttribute('data-session-copy')) {
        const status = target.parentElement.querySelector('[data-copy-status]')
        try {
          await navigator.clipboard.writeText(target.dataset.sessionCopy)
          if (status) status.textContent = 'Copied'
        } catch {
          if (status) status.textContent = 'Copy unavailable; select the value to copy.'
        }
        return
      }
      this._cancelPanelFrames()
      const panel = target.dataset.sessionPanelToggle
      if (panel) {
        const previous = this._panelState.modal
        this._panelState = target.hasAttribute('data-session-context-open')
          ? { ...this._panelState, details: true, modal: this._panelWidth < widths.details ? 'details' : null }
          : changePanel(this._panelState, panel, this._panelWidth)
        if (this._panelState.modal && !previous) this._opener = target
        this._applyPanels(previous)
        if (target.hasAttribute('data-session-context-open')) {
          this._contextFrame = window.requestAnimationFrame(() => {
            if (!panelVisible(this._panelState, 'details', this._panelWidth)) return
            const context = this.el.querySelector('#session-context-details')
            context?.scrollIntoView({ block: 'nearest' })
            context?.focus({ preventScroll: true })
          })
        }
      } else this._closePanel()
    }
    this._panelKey = event => {
      const modal = this._panelState.modal
      if (!modal || event.defaultPrevented) return
      if (event.key === 'Escape') {
        event.preventDefault()
        this._closePanel()
      } else if (event.key === 'Tab') {
        const panel = this.el.querySelector(`[data-session-panel="${modal}"]`)
        const elements = focusableElements(panel)
        const index = elements.indexOf(activeElement())
        if (!elements.length) {
          event.preventDefault()
          panel.focus()
        } else if (event.shiftKey && index <= 0) {
          event.preventDefault()
          elements.at(-1).focus()
        } else if (!event.shiftKey && (index === -1 || index === elements.length - 1)) {
          event.preventDefault()
          elements[0].focus()
        }
      }
    }
    this._panelResize = () => {
      this._cancelPanelFrames()
      const previous = this._panelState.modal
      this._panelState = resizePanels(this._panelState, this._panelWidth, window.innerWidth)
      this._panelWidth = window.innerWidth
      this._applyPanels(previous)
    }
    this.el.addEventListener('click', this._panelClick)
    document.addEventListener('keydown', this._panelKey)
    window.addEventListener('resize', this._panelResize)
    this._applyPanels(null)
  },
  updated() { this._applyPanels(this._panelState.modal) },
  destroyed() {
    this.el.removeEventListener('click', this._panelClick)
    document.removeEventListener('keydown', this._panelKey)
    window.removeEventListener('resize', this._panelResize)
    this._restorePanelBackground()
    this._cancelPanelFrames()
  },
  _cancelPanelFrames() {
    if (this._panelFrame) window.cancelAnimationFrame(this._panelFrame)
    if (this._contextFrame) window.cancelAnimationFrame(this._contextFrame)
    this._panelFrame = null
    this._contextFrame = null
  },
  _closePanel() {
    this._cancelPanelFrames()
    const previous = this._panelState.modal
    this._panelState = { ...this._panelState, modal: null }
    this._applyPanels(previous)
  },
  _restorePanelBackground() {
    for (const [element, inert] of this._inertElements) element.inert = inert
    this._inertElements.clear()
  },
  _applyPanels(previousModal) {
    const modal = this._panelState.modal
    this._restorePanelBackground()
    for (const name of Object.keys(widths)) {
      const panel = this.el.querySelector(`[data-session-panel="${name}"]`)
      if (!panel) continue
      const visible = panelVisible(this._panelState, name, this._panelWidth)
      this.el.dataset[`${name}Open`] = String(visible)
      panel.inert = !visible
      if (modal === name) {
        panel.setAttribute('role', 'dialog')
        panel.setAttribute('aria-modal', 'true')
        panel.setAttribute('tabindex', '-1')
      } else {
        panel.removeAttribute('role')
        panel.removeAttribute('aria-modal')
        panel.removeAttribute('tabindex')
      }
      for (const button of this.el.querySelectorAll(`[data-session-panel-toggle="${name}"]`)) {
        button.setAttribute('aria-expanded', String(visible))
        if (panel.id) button.setAttribute('aria-controls', panel.id)
      }
      for (const button of panel.querySelectorAll('[data-session-panel-close]')) button.hidden = modal !== name
    }
    const backdrop = this.el.querySelector('[data-session-panel-backdrop]')
    if (backdrop) backdrop.hidden = !modal
    if (modal) {
      // Inert siblings through the whole document, including the global appbar.
      let branch = this.el.querySelector(`[data-session-panel="${modal}"]`)
      while (branch && branch !== document.body) {
        for (const sibling of branch.parentElement?.children || []) {
          if (sibling !== branch && sibling !== backdrop) {
            this._inertElements.set(sibling, sibling.inert)
            sibling.inert = true
          }
        }
        branch = branch.parentElement
      }
      if (previousModal !== modal) {
        const panel = this.el.querySelector(`[data-session-panel="${modal}"]`)
        this._panelFrame = window.requestAnimationFrame(() => {
          if (this._panelState.modal === modal) (focusableElements(panel)[0] || panel).focus()
        })
      }
    } else if (previousModal && this._opener?.isConnected) {
      this._opener.focus()
      this._opener = null
    }
  }
}
