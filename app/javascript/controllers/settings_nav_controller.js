import { Controller } from "@hotwired/stimulus"

// 设置页左侧子导航：点击切换显示对应面板（其余面板 hidden，全部表单保持挂载，
// 各表单独立提交到 update 的行为不变）。支持 #hash 直达；兼容飞书推送历史深链
// #weread → 微信读书面板。
const PANEL_ALIASES = { weread: "wechat" }

export default class extends Controller {
  static targets = ["link", "panel"]

  connect() {
    this._onHashChange = () => this.activateFromHash({ scroll: true })
    window.addEventListener("hashchange", this._onHashChange)
    this.activateFromHash({ scroll: window.location.hash !== "" })
  }

  disconnect() {
    window.removeEventListener("hashchange", this._onHashChange)
  }

  switch(event) {
    const id = event.currentTarget.dataset.panelId
    this.activate(id, { scroll: true })
    history.replaceState(null, "", `#${id}`)
  }

  activateFromHash({ scroll }) {
    const raw = (window.location.hash || "").replace("#", "")
    const id = PANEL_ALIASES[raw] || raw
    const panel = this.panelTargets.find((p) => p.dataset.panelId === id)
    if (!panel) {
      if (raw === "") this.activate(this.panelTargets[0]?.dataset.panelId, { scroll: false })
      return
    }
    this.activate(id, { scroll })
  }

  activate(id, { scroll }) {
    if (!id) return
    this.panelTargets.forEach((p) => p.classList.toggle("hidden", p.dataset.panelId !== id))
    this.linkTargets.forEach((l) => l.classList.toggle("active", l.dataset.panelId === id))
    if (scroll) {
      this.panelTargets.find((p) => p.dataset.panelId === id)?.scrollIntoView({ block: "start" })
    }
  }
}
