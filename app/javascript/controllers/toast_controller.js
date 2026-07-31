import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]

  connect() {
    // Convert any initial flash messages (from page load) into toasts
    const flashData = this.element.dataset.flash
    if (flashData) {
      try {
        const flashes = JSON.parse(flashData)
        for (const [type, message] of Object.entries(flashes)) {
          if (message) this.#show(message, type)
        }
      } catch (_) { /* ignore parse errors */ }
      delete this.element.dataset.flash
    }

    // Auto-dismiss any toasts appended via Turbo Stream
    this.#observeNewToasts()
  }

  #observeNewToasts() {
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType === Node.ELEMENT_NODE && node.dataset.toastAutoDismiss !== undefined) {
            // Trigger enter animation
            node.offsetHeight // force reflow
            node.classList.remove("translate-y-4", "opacity-0")
            node.classList.add("translate-y-0", "opacity-100")
            // Auto-dismiss after 5 seconds
            setTimeout(() => this.#dismiss(node), 5000)
          }
        }
      }
    })
    observer.observe(this.containerTarget, { childList: true })
  }

  // Public action: data-action="toast#show"
  // Set message via event detail: dispatchEvent("toast:show", { detail: { message, type } })
  show(event) {
    const { message, type = "success" } = event.detail || event
    this.#show(message, type)
  }

  // Private: create and animate a toast
  #show(message, type) {
    const config = this.#config(type)
    const el = document.createElement("div")
    el.className = [
      "flex items-center gap-3 px-4 py-3 rounded-lg shadow-lg border text-sm",
      "transform transition-all duration-300 ease-out",
      "translate-y-4 opacity-0 pointer-events-auto",
      config.colors
    ].join(" ")

    el.innerHTML = `
      <span class="flex-shrink-0">${config.icon}</span>
      <span class="flex-1">${this.#escapeHtml(message)}</span>
      <button type="button" class="flex-shrink-0 ml-2 opacity-60 hover:opacity-100 transition"
              onclick="this.parentElement.remove()">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
        </svg>
      </button>
    `

    this.containerTarget.appendChild(el)

    // Trigger enter animation (force reflow to ensure transition fires)
    el.offsetHeight // eslint-disable-line no-unused-expressions
    el.classList.remove("translate-y-4", "opacity-0")
    el.classList.add("translate-y-0", "opacity-100")

    // Auto-dismiss after 5 seconds
    setTimeout(() => this.#dismiss(el), 5000)
  }

  #dismiss(el) {
    el.classList.remove("translate-y-0", "opacity-100")
    el.classList.add("opacity-0", "translate-y-4")
    // Remove after transition ends, with a safety fallback
    const cleanup = () => { el.remove() }
    el.addEventListener("transitionend", cleanup, { once: true })
    setTimeout(cleanup, 500) // safety fallback if transitionend never fires
  }

  #config(type) {
    const configs = {
      success: {
        colors: "bg-green-50 border-green-200 text-green-800",
        icon: '<svg class="w-5 h-5 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>'
      },
      error: {
        colors: "bg-red-50 border-red-200 text-red-800",
        icon: '<svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>'
      },
      warning: {
        colors: "bg-yellow-50 border-yellow-200 text-yellow-800",
        icon: '<svg class="w-5 h-5 text-yellow-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4.5c-.77-.833-2.694-.833-3.464 0L3.34 16.5c-.77.833.192 2.5 1.732 2.5z"/></svg>'
      },
      info: {
        colors: "bg-blue-50 border-blue-200 text-blue-800",
        icon: '<svg class="w-5 h-5 text-blue-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>'
      }
    }
    return configs[type] || configs.info
  }

  #escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
