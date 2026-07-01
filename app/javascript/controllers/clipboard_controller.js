import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "icon", "checkIcon"]
  static values = { text: String }

  copy() {
    navigator.clipboard.writeText(this.textValue).then(() => {
      // Swap icons to show success
      this.iconTarget.classList.add("hidden")
      this.checkIconTarget.classList.remove("hidden")

      // Revert after 2 seconds
      setTimeout(() => {
        this.iconTarget.classList.remove("hidden")
        this.checkIconTarget.classList.add("hidden")
      }, 2000)
    }).catch(err => {
      console.error('Failed to copy:', err)
    })
  }
}
