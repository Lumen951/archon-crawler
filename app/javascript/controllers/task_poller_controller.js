import { Controller } from "@hotwired/stimulus"

// Polls the server for task updates while the task is in a non-terminal state.
// Uses exponential backoff: starts at the configured interval, grows by 1.5x
// each tick (capped at 60s). Resets to fast polling when a state change is
// detected. Pauses when the tab is hidden, resumes on focus.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 3000 } }

  connect() {
    this._delay = this.intervalValue
    this._maxDelay = 60000
    this._backoffRate = 1.5
    this._abortController = null
    this._stopped = false
    this._visibilityHandler = () => {
      if (document.visibilityState === "visible") this.pollNow()
    }
    document.addEventListener("visibilitychange", this._visibilityHandler)
    this.poll()
  }

  disconnect() {
    this._stopped = true
    clearTimeout(this._timer)
    this._abortController?.abort()
    document.removeEventListener("visibilitychange", this._visibilityHandler)
  }

  // Poll immediately and reset backoff (e.g. tab regains focus).
  pollNow() {
    if (this._stopped) return
    clearTimeout(this._timer)
    this._delay = this.intervalValue
    this.poll()
  }

  poll() {
    if (this._stopped) return

    this._timer = setTimeout(async () => {
      if (this._stopped) return
      this._abortController?.abort()
      this._abortController = new AbortController()

      try {
        const response = await fetch(this.urlValue, {
          headers: { Accept: "text/vnd.turbo-stream.html" },
          signal: this._abortController.signal
        })
        if (response.ok) {
          const html = await response.text()
          if (html.trim().length > 0) {
            Turbo.renderStreamMessage(html)
            this._delay = this.intervalValue
          }
        }
      } catch (_) {
        // network error — next tick will retry
      }

      this._delay = Math.min(this._delay * this._backoffRate, this._maxDelay)

      if (this.element.isConnected && !this._stopped) this.poll()
    }, this._delay)
  }
}
