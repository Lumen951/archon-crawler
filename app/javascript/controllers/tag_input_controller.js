import { Controller } from "@hotwired/stimulus"

// Chip-style tag input with autocomplete and inline tag creation.
// Users type to search existing tags, select from dropdown, or press Enter to create new ones.
export default class extends Controller {
  static targets = ["input", "dropdown", "chips", "hiddenFields"]

  connect() {
    this.tags = [] // { id, name, color, isNew }
    this._debounceTimer = null
    this._activeIndex = -1
    this._clickOutsideHandler = (e) => {
      if (!this.element.contains(e.target)) this._hideDropdown()
    }
    document.addEventListener('click', this._clickOutsideHandler)
  }

  disconnect() {
    document.removeEventListener('click', this._clickOutsideHandler)
    clearTimeout(this._debounceTimer)
  }

  // Input handler with debounce
  onInput() {
    clearTimeout(this._debounceTimer)
    this._debounceTimer = setTimeout(() => this._search(), 200)
    this._activeIndex = -1
  }

  // Handle Enter key to add tag
  onKeydown(e) {
    if (e.key === 'Enter') {
      e.preventDefault()
      const query = this.inputTarget.value.trim()
      if (query) {
        // If there's an active dropdown item, select it
        const items = this.dropdownTarget.querySelectorAll('[data-tag-item]')
        if (this._activeIndex >= 0 && items[this._activeIndex]) {
          items[this._activeIndex].click()
        } else {
          this._addTag(query)
        }
      }
    } else if (e.key === 'Escape') {
      this._hideDropdown()
    } else if (e.key === 'ArrowDown') {
      e.preventDefault()
      this._navigateDropdown(1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      this._navigateDropdown(-1)
    }
  }

  // Select from dropdown
  selectTag(e) {
    const el = e.currentTarget
    const id = el.dataset.tagId
    const name = el.dataset.tagName
    const color = el.dataset.tagColor
    this._addTag(name, id, color)
  }

  // Remove a chip
  removeTag(e) {
    const index = parseInt(e.currentTarget.dataset.tagIndex)
    this.tags.splice(index, 1)
    this._renderChips()
    this._updateHiddenFields()
  }

  // Get tag names for form submission
  get tagNames() {
    return this.tags.map(t => t.name)
  }

  _addTag(name, existingId = null, color = null) {
    // Check for duplicates (case-insensitive)
    const normalized = name.toLowerCase().trim()
    if (this.tags.some(t => t.name.toLowerCase() === normalized)) {
      this.inputTarget.value = ''
      this._hideDropdown()
      return
    }

    this.tags.push({
      id: existingId || null,
      name: name.trim(),
      color: color || '#6366f1',
      isNew: !existingId
    })

    this.inputTarget.value = ''
    this._hideDropdown()
    this._renderChips()
    this._updateHiddenFields()
  }

  async _search() {
    const query = this.inputTarget.value.trim()
    if (query.length === 0) {
      this._hideDropdown()
      return
    }

    try {
      const resp = await fetch(`/accounts/tag_suggestions?q=${encodeURIComponent(query)}`, {
        headers: { 'Accept': 'application/json' }
      })
      const tags = await resp.json()
      this._renderDropdown(tags, query)
    } catch (_) {
      this._hideDropdown()
    }
  }

  _renderDropdown(tags, query) {
    const existingNames = new Set(this.tags.map(t => t.name.toLowerCase()))
    const filtered = tags.filter(t => !existingNames.has(t.name.toLowerCase()))

    let html = ''
    filtered.forEach((tag, i) => {
      html += `<button type="button" data-tag-item data-tag-id="${tag.id}" data-tag-name="${this._escape(tag.name)}" data-tag-color="${tag.color}"
        class="w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-bg-secondary transition ${i === this._activeIndex ? 'bg-bg-secondary' : ''}">
        <span class="w-3 h-3 rounded-full flex-shrink-0" style="background-color: ${tag.color}"></span>
        <span class="text-text-primary">${this._escape(tag.name)}</span>
        <span class="text-xs text-text-muted ml-auto">${tag.count}</span>
      </button>`
    })

    // "Create new tag" option if query doesn't exactly match any existing tag
    const exactMatch = filtered.some(t => t.name.toLowerCase() === query.toLowerCase())
    if (!exactMatch && query.length > 0) {
      html += `<button type="button" data-tag-item data-tag-name="${this._escape(query)}"
        class="w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-bg-secondary transition border-t border-border-primary">
        <svg class="w-4 h-4 text-brand" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 6v6m0 0v6m0-6h6m-6 0H6"/></svg>
        <span class="text-brand font-medium">创建标签「${this._escape(query)}」</span>
      </button>`
    }

    if (html) {
      this.dropdownTarget.innerHTML = html
      this.dropdownTarget.classList.remove('hidden')
      // Bind click events
      this.dropdownTarget.querySelectorAll('[data-tag-item]').forEach(el => {
        el.addEventListener('click', (e) => {
          this._addTag(el.dataset.tagName, el.dataset.tagId, el.dataset.tagColor)
        })
      })
    } else {
      this._hideDropdown()
    }
  }

  _renderChips() {
    let html = ''
    this.tags.forEach((tag, i) => {
      const bgColor = tag.isNew ? '#f59e0b20' : `${tag.color}20`
      const textColor = tag.isNew ? '#f59e0b' : tag.color
      const dotColor = tag.isNew ? '#f59e0b' : tag.color
      const newBadge = tag.isNew ? '<span class="text-[10px] opacity-70">新建</span>' : ''
      html += `<span class="inline-flex items-center gap-1 px-2 py-1 rounded-full text-xs font-medium" style="background-color: ${bgColor}; color: ${textColor}">
        <span class="w-2 h-2 rounded-full flex-shrink-0" style="background-color: ${dotColor}"></span>
        ${this._escape(tag.name)}${newBadge}
        <button type="button" data-tag-index="${i}" data-action="click->tag-input#removeTag"
          class="ml-1 hover:opacity-70 transition" title="移除">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
        </button>
      </span>`
    })
    this.chipsTarget.innerHTML = html
  }

  _updateHiddenFields() {
    this.hiddenFieldsTarget.innerHTML = ''
    this.tags.forEach(tag => {
      const input = document.createElement('input')
      input.type = 'hidden'
      input.name = 'tag_names[]'
      input.value = tag.name
      this.hiddenFieldsTarget.appendChild(input)
    })
  }

  _hideDropdown() {
    this.dropdownTarget.classList.add('hidden')
    this.dropdownTarget.innerHTML = ''
    this._activeIndex = -1
  }

  _navigateDropdown(direction) {
    const items = this.dropdownTarget.querySelectorAll('[data-tag-item]')
    if (items.length === 0) return

    this._activeIndex += direction
    if (this._activeIndex < 0) this._activeIndex = items.length - 1
    if (this._activeIndex >= items.length) this._activeIndex = 0

    items.forEach((item, i) => {
      item.classList.toggle('bg-bg-secondary', i === this._activeIndex)
    })
  }

  _escape(str) {
    const div = document.createElement('div')
    div.textContent = str
    return div.innerHTML
  }
}
