import { Controller } from "@hotwired/stimulus"

// Handles follow/unfollow toggle on tag chips in the accounts index filter bar.
// Sends AJAX POST to toggle_tag_follow and updates the icon state.
export default class extends Controller {
  static values = { tagId: Number, followed: Boolean }

  connect() {
    this._updateIcon()
  }

  async toggle(e) {
    e.preventDefault()
    e.stopPropagation()

    try {
      const resp = await fetch('/accounts/toggle_tag_follow', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': this._csrfToken()
        },
        body: JSON.stringify({ tag_id: this.tagIdValue })
      })
      const data = await resp.json()
      if (data.followed !== undefined) {
        this.followedValue = data.followed
        this._updateIcon()
      }
    } catch (_) {
      // silently fail
    }
  }

  _updateIcon() {
    const icon = this.element.querySelector('[data-follow-icon]')
    if (!icon) return

    if (this.followedValue) {
      icon.classList.remove('text-text-muted', 'hover:text-yellow-500')
      icon.classList.add('text-yellow-500')
      icon.innerHTML = `<svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>`
    } else {
      icon.classList.remove('text-yellow-500')
      icon.classList.add('text-text-muted', 'hover:text-yellow-500')
      icon.innerHTML = `<svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z"/></svg>`
    }
  }

  _csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ''
  }
}
