import { Controller } from "@hotwired/stimulus"

// 下拉选择变化后自动提交所在表单，省掉一次「搜索」点击
export default class extends Controller {
  connect() {
    this.onChange = () => {
      const form = this.element.form
      if (form) form.requestSubmit()
    }
    this.element.addEventListener("change", this.onChange)
  }

  disconnect() {
    this.element.removeEventListener("change", this.onChange)
  }
}
