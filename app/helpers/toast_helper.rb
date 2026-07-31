module ToastHelper
  # Renders a Turbo Stream action that appends a toast notification.
  #
  # Usage in controllers:
  #   render turbo_stream: toast_stream("Saved!", type: :success)
  #
  # Types: :success, :error, :warning, :info
  def toast_stream(message, type: :success)
    type = type.to_s
    config = toast_config(type)
    classes = [
      "flex items-center gap-3 px-4 py-3 rounded-lg shadow-lg border text-sm",
      "transform transition-all duration-300 ease-out translate-y-4 opacity-0 pointer-events-auto",
      config[:colors]
    ].join(" ")

    toast_html = tag.div(class: classes, "data-toast-auto-dismiss" => "") do
      tag.span(config[:icon].html_safe, class: "flex-shrink-0") +
      tag.span(message, class: "flex-1") +
      tag.button(
        type: "button",
        class: "flex-shrink-0 ml-2 opacity-60 hover:opacity-100 transition",
        onclick: "this.parentElement.remove()"
      ) do
        '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>'.html_safe
      end
    end

    tag.turbo_stream(action: "append", target: "toasts") do
      tag.template { toast_html }
    end
  end

  private

  def toast_config(type)
    configs = {
      "success" => { colors: "bg-green-50 border-green-200 text-green-800", icon: '<svg class="w-5 h-5 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>' },
      "error"   => { colors: "bg-red-50 border-red-200 text-red-800", icon: '<svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>' },
      "warning" => { colors: "bg-yellow-50 border-yellow-200 text-yellow-800", icon: '<svg class="w-5 h-5 text-yellow-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4.5c-.77-.833-2.694-.833-3.464 0L3.34 16.5c-.77.833.192 2.5 1.732 2.5z"/></svg>' },
      "info"    => { colors: "bg-blue-50 border-blue-200 text-blue-800", icon: '<svg class="w-5 h-5 text-blue-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>' }
    }
    configs[type] || configs["info"]
  end
end
