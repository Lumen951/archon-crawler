import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "backdrop", "tagCheckbox"]

  connect() {
    // Close on backdrop click
    this.backdropTarget.addEventListener("click", this.close.bind(this))
    // Close on Escape key
    this.escapeHandler = this.onEscape.bind(this)
    document.addEventListener("keydown", this.escapeHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.escapeHandler)
  }

  open() {
    this.dialogTarget.classList.remove("hidden")
    // Trigger reflow for animation
    this.dialogTarget.offsetHeight
    this.dialogTarget.classList.add("opacity-100")
    this.dialogTarget.querySelector("[data-modal-backdrop]")?.classList.add("opacity-100")
    // Prevent body scroll
    document.body.style.overflow = "hidden"
  }

  close() {
    this.dialogTarget.classList.add("opacity-0")
    this.dialogTarget.querySelector("[data-modal-backdrop]")?.classList.add("opacity-0")
    setTimeout(() => {
      this.dialogTarget.classList.add("hidden")
      this.dialogTarget.classList.remove("opacity-0", "opacity-100")
      document.body.style.overflow = ""
    }, 200)
  }

  onEscape(event) {
    if (event.key === "Escape" && !this.dialogTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.tagCheckboxTargets.forEach(checkbox => {
      checkbox.checked = checked
    })
  }
}
