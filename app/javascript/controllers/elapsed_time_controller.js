import { Controller } from "@hotwired/stimulus"

// Displays a running elapsed-time counter (HH:MM:SS) from a given start timestamp.
// Usage:
//   <span data-controller="elapsed-time"
//         data-elapsed-time-start-value="1700000000">
//     <span data-elapsed-time-target="display"></span>
//   </span>
export default class extends Controller {
  static targets = ["display"]
  static values = { start: Number }

  connect() {
    this._update()
    this._timer = setInterval(() => this._update(), 1000)
  }

  disconnect() {
    clearInterval(this._timer)
  }

  _update() {
    const elapsed = Math.floor(Date.now() / 1000) - this.startValue
    if (elapsed < 0) return

    const hours = Math.floor(elapsed / 3600)
    const minutes = Math.floor((elapsed % 3600) / 60)
    const seconds = elapsed % 60

    const pad = n => String(n).padStart(2, "0")
    this.displayTarget.textContent = `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`
  }
}
