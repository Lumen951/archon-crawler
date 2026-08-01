import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "input"]
  static values = { url: String }

  connect() {
    this.editing = false
  }

  edit() {
    if (this.editing) return
    this.editing = true

    const currentText = this.displayTarget.textContent.trim()
    this.displayTarget.classList.add("hidden")

    // Hide the edit icon
    const editIcon = this.element.querySelector("[data-edit-icon]")
    if (editIcon) editIcon.classList.add("hidden")

    const input = document.createElement("input")
    input.type = "text"
    input.value = currentText
    input.className = "text-2xl sm:text-3xl font-bold text-text-primary border border-border-primary rounded px-2 py-1 w-full max-w-md focus:outline-none focus:ring-2 focus:ring-brand/50 bg-bg-card"
    this.inputTarget.innerHTML = ""
    this.inputTarget.appendChild(input)
    this.inputTarget.classList.remove("hidden")
    input.focus()
    input.select()

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.save(input, currentText)
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.cancel(currentText)
      }
    })

    input.addEventListener("blur", () => {
      // Small delay to allow click events to fire first
      setTimeout(() => {
        if (this.editing) {
          this.save(input, currentText)
        }
      }, 150)
    })
  }

  save(input, originalText) {
    const newText = input.value.trim()
    if (!this.editing) return

    if (newText === originalText || newText === "") {
      this.cancel(originalText)
      return
    }

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": csrfToken
      },
      body: JSON.stringify({ account: { nickname: newText } })
    })
      .then(response => {
        if (response.ok) {
          return response.json().then(data => {
            // Update the display text
            this.displayTarget.textContent = data.nickname
            // Exit edit mode
            this.cancel(data.nickname)
            // Show success toast
            this.showToast("帐号名称已更新", "success")
          })
        } else {
          return response.json().then(data => {
            this.cancel(originalText)
            const errorMsg = data.errors ? data.errors.join(", ") : "更新失败"
            this.showToast(errorMsg, "error")
          }).catch(() => {
            this.cancel(originalText)
            this.showToast("更新失败", "error")
          })
        }
      })
      .catch(() => {
        this.cancel(originalText)
        this.showToast("网络错误，请重试", "error")
      })
  }

  cancel(originalText) {
    this.editing = false
    this.inputTarget.innerHTML = ""
    this.inputTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")

    // Show the edit icon again
    const editIcon = this.element.querySelector("[data-edit-icon]")
    if (editIcon) editIcon.classList.remove("hidden")
  }

  showToast(message, type = "success") {
    const toasts = document.getElementById("toasts")
    if (!toasts) return

    const colors = {
      success: "bg-green-50 border-green-200 text-green-800",
      error: "bg-red-50 border-red-200 text-red-800"
    }
    const icons = {
      success: '<svg class="w-5 h-5 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>',
      error: '<svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>'
    }

    const toast = document.createElement("div")
    toast.className = `flex items-center gap-3 px-4 py-3 rounded-lg shadow-lg border text-sm transform transition-all duration-300 ease-out translate-y-4 opacity-0 pointer-events-auto ${colors[type]}`
    toast.setAttribute("data-toast-auto-dismiss", "")
    toast.innerHTML = `
      <span class="flex-shrink-0">${icons[type]}</span>
      <span class="flex-1">${message}</span>
      <button type="button" class="flex-shrink-0 ml-2 opacity-60 hover:opacity-100 transition" onclick="this.parentElement.remove()">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
      </button>
    `
    toasts.appendChild(toast)

    // Trigger animation
    requestAnimationFrame(() => {
      toast.classList.remove("translate-y-4", "opacity-0")
      toast.classList.add("translate-y-0", "opacity-100")
    })

    // Auto-dismiss after 5 seconds
    setTimeout(() => {
      toast.classList.remove("translate-y-0", "opacity-100")
      toast.classList.add("opacity-0", "translate-y-4")
      setTimeout(() => toast.remove(), 300)
    }, 5000)
  }
}
