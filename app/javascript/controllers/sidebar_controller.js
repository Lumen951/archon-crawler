import { Controller } from "@hotwired/stimulus"

// GitLab 式侧边栏：桌面端常驻，移动端抽屉化（汉堡按钮开关 + 遮罩点击关闭）。
// 导航完成后自动收起，避免抽屉遮挡新页面。
export default class extends Controller {
  static targets = ["panel", "overlay"]

  connect() {
    this._onLoad = () => this.close()
    document.addEventListener("turbo:load", this._onLoad)
  }

  disconnect() {
    document.removeEventListener("turbo:load", this._onLoad)
  }

  open() {
    this.panelTarget.classList.remove("-translate-x-full")
    this.overlayTarget?.classList.remove("hidden")
  }

  close() {
    this.panelTarget?.classList.add("-translate-x-full")
    this.overlayTarget?.classList.add("hidden")
  }

  toggle() {
    this.panelTarget.classList.contains("-translate-x-full") ? this.open() : this.close()
  }
}
