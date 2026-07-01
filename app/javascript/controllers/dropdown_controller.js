import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel"]

  toggle() {
    this.panelTarget.classList.toggle("hidden")
  }

  close(event) {
    if (!this.element.contains(event.target)) {
      if (this.hasPanelTarget) this.panelTarget.classList.add("hidden")
    }
  }

  connect() {
    this._closeHandler = this.close.bind(this)
    document.addEventListener("click", this._closeHandler)
  }

  disconnect() {
    document.removeEventListener("click", this._closeHandler)
  }
}
