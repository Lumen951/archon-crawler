import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "toggle", "icon"]

  toggle() {
    const expanded = !this.contentTarget.classList.contains("hidden")
    this.contentTarget.classList.toggle("hidden")

    if (this.hasIconTarget) {
      this.iconTarget.style.transform = expanded ? "" : "rotate(180deg)"
    }

    if (this.hasToggleTarget) {
      // Save the icon element before clearing
      const icon = this.hasIconTarget ? this.iconTarget : null
      const count = this.contentTarget.querySelectorAll(":scope > div").length

      if (expanded) {
        this.toggleTarget.innerHTML = `展开剩余 ${count} 个帐号 `
      } else {
        this.toggleTarget.innerHTML = "收起 "
      }

      // Re-append the icon
      if (icon) {
        this.toggleTarget.appendChild(icon)
      }
    }
  }
}
