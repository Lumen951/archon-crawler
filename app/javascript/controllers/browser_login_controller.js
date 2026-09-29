import { Controller } from "@hotwired/stimulus"

// 远程浏览器登录：服务端容器里的受管 Chromium 打开平台登录页，这里轮询
// 截图展示，并把点击 / 滚动 / 键盘事件转发给服务端，用户在本页"遥控"完成
// 登录。检测到登录态后服务端自动把 Cookie 存入对应会话槽位。
//
// 服务端契约（见 BrowserLogin::Session / Admin::SettingsController）：
//   POST start_url    {provider}                        → { session_id, label, resumed, logged_in }
//   GET  frame_url    ?session_id[&force_save=1]        → { image, url, logged_in, saved, message[, status:"expired"] }
//   POST interact_url {session_id, event:{type,...}}    → { ok } 或 { error }
//   POST stop_url     {session_id}                      → { stopped }
//
// 事件类型：
//   click{x,y} / mousedown{x,y}+mousemove{x,y}*+mouseup{x,y}（滑块拖拽，按下后逐个实时转发）
//   scroll{x,y,dx,dy} / text{text} / key{key} / navigate{url} / refresh
// 坐标一律按截图原始分辨率（naturalWidth/Height）映射，前后端无需约定视口。
export default class extends Controller {
  static targets = ["viewer", "screen", "status", "urlInput", "textInput", "openButton"]
  static values = {
    provider: String,
    startUrl: String,
    frameUrl: String,
    interactUrl: String,
    stopUrl: String,
    interval: { type: Number, default: 1000 }
  }

  connect() {
    this.sessionId = null
    this.pollTimer = null
    this.inFlight = false
    this.sendQueue = Promise.resolve()
    this.dragging = null
    this.dragPollTimer = null
    this.boundKeydown = (e) => this.onKeydown(e)
    this.boundPointerMove = (e) => this.onWindowPointerMove(e)
    this.boundPointerUp = (e) => this.onWindowPointerUp(e)
  }

  disconnect() {
    this.stopDrag()
    this.stopLoop()
    document.removeEventListener("keydown", this.boundKeydown)
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  async open() {
    this.openButtonTarget.disabled = true
    this.setStatus("正在启动登录浏览器...", "text-gray-500")
    this.viewerTarget.classList.remove("hidden")

    try {
      const resp = await fetch(this.startUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken },
        body: JSON.stringify({ provider: this.providerValue })
      })
      const data = await resp.json()
      if (!resp.ok) throw new Error(data.error || "启动失败")

      this.sessionId = data.session_id
      this.setStatus(
        data.resumed ? `${data.label}：已接回进行中的登录会话` : `${data.label}：请在下方页面完成登录`,
        "text-gray-500"
      )
      document.addEventListener("keydown", this.boundKeydown)
      this.startLoop()
    } catch (err) {
      this.setStatus(`启动失败: ${err.message}`, "text-red-600")
      this.openButtonTarget.disabled = false
    }
  }

  startLoop() {
    this.pollTimer = setTimeout(async () => {
      await this.poll()
      if (this.sessionId) this.startLoop()
    }, this.intervalValue)
  }

  stopLoop() {
    if (this.pollTimer) {
      clearTimeout(this.pollTimer)
      this.pollTimer = null
    }
    this.sessionId = null
  }

  async poll(forceSave = false) {
    if (!this.sessionId || this.inFlight) return
    this.inFlight = true

    try {
      if (document.hidden) return

      const url = `${this.frameUrlValue}?session_id=${encodeURIComponent(this.sessionId)}${forceSave ? "&force_save=1" : ""}`
      const resp = await fetch(url, { headers: { "X-CSRF-Token": this.csrfToken } })
      const data = await resp.json()

      if (data.status === "expired") {
        this.stopLoop()
        this.setStatus("登录会话已过期，请重新打开", "text-red-600")
        return
      }
      if (!resp.ok) throw new Error(data.error || `HTTP ${resp.status}`)

      if (data.image) {
        this.screenTarget.src = `data:${data.image_mime};base64,${data.image}`
        // 地址栏跟随远程页面，但用户正在编辑时不打断
        if (document.activeElement !== this.urlInputTarget) {
          this.urlInputTarget.value = data.url || ""
        }
      }

      if (data.save_error) {
        this.setStatus(data.message, "text-red-600")
      } else if (data.saved) {
        this.setStatus(`${data.message}`, "text-green-600 font-semibold")
      } else {
        this.setStatus(data.message || "等待登录...", "text-gray-500")
      }
    } catch (err) {
      // 单次轮询失败（网络抖动 / CDP 短暂冲突）不终止循环，下个周期自愈
      this.setStatus(`连接中断，正在重试: ${err.message}`, "text-yellow-600")
    } finally {
      this.inFlight = false
    }
  }

  // 事件按顺序串行发送：拖拽的 down→move*→up 序列不能乱序
  sendEvent(event) {
    if (!this.sessionId) return
    this.sendQueue = this.sendQueue.then(() => this.postEvent(event)).catch(() => {})
  }

  async postEvent(event) {
    if (!this.sessionId) return
    try {
      const resp = await fetch(this.interactUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken },
        body: JSON.stringify({ session_id: this.sessionId, event })
      })
      const data = await resp.json()
      if (data.status === "expired") {
        this.stopLoop()
        this.setStatus("登录会话已过期，请重新打开", "text-red-600")
      }
    } catch (err) {
      // 静默：下一帧截图会反映事件是否生效
    }
  }

  // ── 画布交互：坐标按截图原始分辨率换算 ────────────────

  toScreenCoords(e) {
    const rect = this.screenTarget.getBoundingClientRect()
    const scaleX = this.screenTarget.naturalWidth / rect.width
    const scaleY = this.screenTarget.naturalHeight / rect.height
    return { x: (e.clientX - rect.left) * scaleX, y: (e.clientY - rect.top) * scaleY }
  }

  // 按下即开始拖拽：mousedown 立即上屏，之后 pointermove 逐个转发 mousemove，
  // 松开发 mouseup。原地按下松开就是一次普通点击。滑块拼图验证靠这套事件
  // 跟手移动；拖拽期间截图加速刷新，便于对准拼图缺口。
  onScreenPointerDown(e) {
    if (e.button !== 0 || !this.sessionId) return
    e.preventDefault()
    const { x, y } = this.toScreenCoords(e)
    this.dragging = { startX: x, startY: y, lastX: x, lastY: y, lastSentAt: 0, moved: false }
    this.sendEvent({ type: "mousedown", x, y })
    this.dragPollTimer = setInterval(() => this.poll(), 500)
    window.addEventListener("pointermove", this.boundPointerMove)
    window.addEventListener("pointerup", this.boundPointerUp)
  }

  onWindowPointerMove(e) {
    if (!this.dragging) return
    const { x, y } = this.toScreenCoords(e)
    if (Math.hypot(x - this.dragging.lastX, y - this.dragging.lastY) < 2) return
    const now = performance.now()
    if (now - this.dragging.lastSentAt < 60) return
    this.dragging.lastSentAt = now
    this.dragging.lastX = x
    this.dragging.lastY = y
    this.dragging.moved = true
    this.sendEvent({ type: "mousemove", x, y })
    this.setStatus(
      `拖动中 Δ(${Math.round(x - this.dragging.startX)}, ${Math.round(y - this.dragging.startY)})`,
      "text-blue-600 font-semibold"
    )
  }

  onWindowPointerUp(e) {
    if (!this.dragging) return
    const { x, y } = this.toScreenCoords(e)
    const moved = this.dragging.moved
    this.stopDrag()
    this.sendEvent({ type: "mouseup", x, y })
    this.setStatus(moved ? "拖动完成，等待画面刷新..." : "已点击", "text-gray-500")
    this.poll()
  }

  stopDrag() {
    this.dragging = null
    if (this.dragPollTimer) {
      clearInterval(this.dragPollTimer)
      this.dragPollTimer = null
    }
    window.removeEventListener("pointermove", this.boundPointerMove)
    window.removeEventListener("pointerup", this.boundPointerUp)
  }

  onScreenWheel(e) {
    e.preventDefault()
    const { x, y } = this.toScreenCoords(e)
    this.sendEvent({ type: "scroll", x, y, dx: e.deltaX, dy: e.deltaY })
  }

  // ── 键盘：焦点不在辅助输入框时，把按键直接转发给远程页面 ──

  onKeydown(e) {
    if (this.viewerTarget.classList.contains("hidden")) return
    if (e.target === this.textInputTarget || e.target === this.urlInputTarget) return

    const specialKeys = ["Enter", "Backspace", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Delete", "Home", "End"]
    if (specialKeys.includes(e.key) || e.key.length === 1) {
      if (e.ctrlKey || e.metaKey || e.altKey) return
      e.preventDefault()
      this.sendEvent({ type: "key", key: e.key })
    }
  }

  // 地址栏导航：粘贴文章/验证页链接后，让远程浏览器直接打开
  goTo() {
    const url = (this.urlInputTarget.value || "").trim()
    if (!url) return
    this.setStatus(`正在打开: ${url.slice(0, 80)}`, "text-gray-500")
    this.sendEvent({ type: "navigate", url })
  }

  sendText() {
    const text = this.textInputTarget.value
    if (!text) return
    this.sendEvent({ type: "text", text })
    this.textInputTarget.value = ""
  }

  sendEnter() {
    this.sendEvent({ type: "key", key: "Enter" })
  }

  // ── 工具栏 ──────────────────────────────────────────

  refresh() {
    this.sendEvent({ type: "refresh" })
  }

  save() {
    this.setStatus("正在保存登录态...", "text-gray-500")
    this.poll(true)
  }

  async close() {
    const sessionId = this.sessionId
    this.stopDrag()
    this.stopLoop()
    document.removeEventListener("keydown", this.boundKeydown)
    this.viewerTarget.classList.add("hidden")
    this.openButtonTarget.disabled = false

    if (sessionId) {
      try {
        await fetch(this.stopUrlValue, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken },
          body: JSON.stringify({ session_id: sessionId })
        })
      } catch (err) { /* 会话超时后服务端会自行清理 */ }
      // 刷新页面让登录状态面板更新
      setTimeout(() => Turbo.visit(window.location.href, { action: "replace" }), 300)
    }
  }

  setStatus(text, classes) {
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-sm ${classes}`
  }
}
