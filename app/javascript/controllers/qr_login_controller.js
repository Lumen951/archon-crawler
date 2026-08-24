import { Controller } from "@hotwired/stimulus"

// 扫码登录（微信读书 / 微信公众号平台共用）。
//
// 点击按钮 → POST 取二维码（服务端返回 data URI，不依赖第三方二维码渲染服务）
// → 每 2.5 秒轮询一次状态 → 成功后刷新页面。
// 平台差异全部在服务端的 QrLogin 策略里，这里只认统一的 JSON 契约:
//   POST request_url {provider}      → { token, image_src }
//   GET  status_url  {provider,token} → { status: waiting|scanned|success|expired|error, message }
export default class extends Controller {
  static targets = ["area", "image", "status", "spinner", "button"]
  static values = {
    provider: String,
    requestUrl: String,
    statusUrl: String,
    buttonLabel: { type: String, default: "获取登录二维码" },
    interval: { type: Number, default: 2500 }
  }

  connect() {
    this.token = null
    this.timer = null
  }

  disconnect() {
    this.stopPolling()
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  async requestQrCode() {
    this.stopPolling()
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "获取中..."

    try {
      const resp = await fetch(this.requestUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken },
        body: JSON.stringify({ provider: this.providerValue })
      })

      const data = await resp.json()
      if (!resp.ok) throw new Error(data.error || "获取二维码失败")

      this.token = data.token
      this.imageTarget.src = data.image_src
      this.imageTarget.style.opacity = "1"
      this.imageTarget.onerror = () => this.fail("二维码图片加载失败，请重试")
      this.areaTarget.classList.remove("hidden")
      this.setStatus("等待扫码...", "text-gray-500")
      this.spinnerTarget.classList.remove("hidden")
      this.buttonTarget.disabled = false
      this.buttonTarget.textContent = "重新获取二维码"

      this.startPolling()
    } catch (err) {
      this.areaTarget.classList.remove("hidden")
      this.fail(`获取二维码失败: ${err.message}`)
    }
  }

  startPolling() {
    this.timer = setInterval(() => this.poll(), this.intervalValue)
  }

  async poll() {
    try {
      const url = `${this.statusUrlValue}?provider=${encodeURIComponent(this.providerValue)}&token=${encodeURIComponent(this.token)}`
      const resp = await fetch(url, { headers: { "X-CSRF-Token": this.csrfToken } })
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`)

      const data = await resp.json()

      switch (data.status) {
        case "waiting":
          this.setStatus(data.message || "等待扫码...", "text-gray-500")
          break
        case "scanned":
          this.setStatus(data.message || "已扫码，请在手机上确认登录...", "text-blue-600 font-semibold")
          break
        case "success":
          this.stopPolling()
          this.spinnerTarget.classList.add("hidden")
          this.setStatus(`${data.message || "登录成功"}，页面即将刷新...`, "text-green-600 font-semibold")
          this.imageTarget.style.opacity = "0.5"
          setTimeout(() => window.location.reload(), 1500)
          break
        case "expired":
          this.fail("二维码已过期，请重新获取")
          break
        default:
          this.fail(`错误: ${data.message || "未知错误"}`)
      }
    } catch (err) {
      this.fail(`轮询出错: ${err.message}`)
    }
  }

  stopPolling() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
    if (this.hasButtonTarget) this.buttonTarget.disabled = false
  }

  fail(message) {
    this.stopPolling()
    this.spinnerTarget.classList.add("hidden")
    this.setStatus(message, "text-red-600")
    this.buttonTarget.textContent = this.buttonLabelValue
  }

  setStatus(text, classes) {
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-sm mt-3 ${classes}`
  }
}
