import { Controller } from "@hotwired/stimulus"

// Manages bulk selection of accounts with checkboxes, select-all-on-page,
// and select-all-matching modes. Works with the sticky action bar.
export default class extends Controller {
  static targets = ["checkbox", "selectAll", "count", "actionBar", "selectMatching", "matchingCount"]
  static values = { total: Number, scope: String }

  connect() {
    this.selected = new Set()
    this._loadFromStorage()
    this._updateUI()
  }

  disconnect() {
    this._saveToStorage()
  }

  // Toggle individual checkbox
  toggle(e) {
    const id = e.target.value
    if (e.target.checked) {
      this.selected.add(id)
    } else {
      this.selected.delete(id)
      // If we uncheck one, disable "select all matching" mode
      this._setSelectAllMode(false)
    }
    this._updateUI()
  }

  // Toggle all on current page
  toggleAll(e) {
    const checked = e.target.checked
    this.checkboxTargets.forEach(cb => {
      cb.checked = checked
      const id = cb.value
      if (checked) {
        this.selected.add(id)
      } else {
        this.selected.delete(id)
      }
    })
    this._setSelectAllMode(false)
    this._updateUI()
  }

  // Select all matching the current filter (across all pages)
  selectAllMatching() {
    this._setSelectAllMode(true)
    this._updateUI()
  }

  // Deselect all matching
  deselectAllMatching() {
    this._setSelectAllMode(false)
    this.selected.clear()
    this.checkboxTargets.forEach(cb => cb.checked = false)
    this._updateUI()
  }

  // Clear all selections
  clearAll() {
    this.selected.clear()
    this._setSelectAllMode(false)
    this.checkboxTargets.forEach(cb => cb.checked = false)
    this._updateUI()
  }

  // Before form submit: populate hidden fields and close dropdown
  submitAndClose(e) {
    this.prepareSubmit(e)
    // Close parent dropdown
    const dropdown = e.target.closest('[data-controller="dropdown"]')
    if (dropdown) {
      const panel = dropdown.querySelector('[data-dropdown-target="panel"]')
      if (panel) panel.classList.add('hidden')
    }
  }

  // Before form submit: populate hidden fields
  prepareSubmit(e) {
    const form = e.target
    // Remove old hidden fields
    form.querySelectorAll('input[name="account_ids[]"]').forEach(el => el.remove())
    form.querySelectorAll('input[name="select_all"]').forEach(el => el.remove())
    form.querySelectorAll('input[name^="q["]').forEach(el => el.remove())

    if (this._isSelectAllMode()) {
      const input = document.createElement('input')
      input.type = 'hidden'
      input.name = 'select_all'
      input.value = 'true'
      form.appendChild(input)

      // Include current filter/query params from URL so the server
      // resolves the filtered scope instead of operating on all records
      const urlParams = new URLSearchParams(window.location.search)
      urlParams.forEach((value, key) => {
        if (key.startsWith('q[')) {
          const qInput = document.createElement('input')
          qInput.type = 'hidden'
          qInput.name = key
          qInput.value = value
          form.appendChild(qInput)
        }
      })
      // 保留当前 tab（scope=event 为活动调研），服务端 select-all 按 tab 圈定范围
      const scope = urlParams.get('scope')
      if (scope) {
        const scopeInput = document.createElement('input')
        scopeInput.type = 'hidden'
        scopeInput.name = 'scope'
        scopeInput.value = scope
        form.appendChild(scopeInput)
      }
    } else {
      this.selected.forEach(id => {
        const input = document.createElement('input')
        input.type = 'hidden'
        input.name = 'account_ids[]'
        input.value = id
        form.appendChild(input)
      })
    }
  }

  _setSelectAllMode(value) {
    const el = document.querySelector('[data-bulk-selector-select-all-mode]')
    if (el) el.dataset.bulkSelectorSelectAllMode = value ? 'true' : 'false'
    this._selectAllMode = value
  }

  _isSelectAllMode() {
    return this._selectAllMode === true
  }

  _updateUI() {
    const count = this.selected.size
    const isAllMode = this._isSelectAllMode()

    // Update count display
    if (this.hasCountTarget) {
      this.countTarget.textContent = isAllMode ? this.totalValue : count
    }

    // Show/hide action bar
    if (this.hasActionBarTarget) {
      this.actionBarTarget.classList.toggle('hidden', count === 0 && !isAllMode)
    }

    // Show/hide "select matching" button and mode indicator
    if (this.hasSelectMatchingTarget) {
      this.selectMatchingTarget.classList.toggle('hidden', count === 0 || isAllMode)
    }

    // Update select-all checkbox state
    if (this.hasSelectAllTarget) {
      const checkboxes = this.checkboxTargets
      const checkedCount = checkboxes.filter(cb => cb.checked).length
      this.selectAllTarget.checked = checkboxes.length > 0 && checkedCount === checkboxes.length
      this.selectAllTarget.indeterminate = checkedCount > 0 && checkedCount < checkboxes.length
    }

    // Toggle select-all-matching banner
    const banner = document.querySelector('[data-select-all-banner]')
    if (banner) banner.classList.toggle('hidden', !isAllMode)

    this._saveToStorage()
  }

  // 选中状态按 scope（帐号 tab）隔离，切换 tab 时互不残留
  _storageKey() {
    return `bulk_selected:${this.scopeValue || "default"}`
  }

  _saveToStorage() {
    try {
      sessionStorage.setItem(this._storageKey(), JSON.stringify([...this.selected]))
    } catch (_) {}
  }

  _loadFromStorage() {
    try {
      const data = sessionStorage.getItem(this._storageKey())
      if (data) {
        const ids = JSON.parse(data)
        ids.forEach(id => this.selected.add(id))
        // Restore checkbox states
        this.checkboxTargets.forEach(cb => {
          cb.checked = this.selected.has(cb.value)
        })
      }
    } catch (_) {}
  }
}
