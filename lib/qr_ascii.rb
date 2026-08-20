# frozen_string_literal: true

require "rqrcode"

# 将文本内容编码为二维码并渲染成终端可显示的 Unicode 半块字符画。
#
# 通过 rqrcode_core 的 module 矩阵（truthy = 深色模块）逐像素映射：
#   - 默认适配深色终端：深色模块 → 终端背景（空格），浅色模块 → 亮色前景块
#   - invert: true 适配浅色终端（反转前景/背景）
#
# 两种风格：
#   - :half_block（默认）：两行模块合并为一行，用 "▄"（上半）/"▀"（下半）/"█"（全亮）
#   - :full_block：每个模块用两个字符（"██" / "  "）表示，更宽但更接近正方形
class QrAscii
  # glyph[top_foreground?1:0][bottom_foreground?1:0]
  HALF_BLOCK = [[ " ", "▄" ], [ "▀", "█" ]].freeze

  def self.render(text, invert: false, quiet_zone: 2, style: :half_block)
    qr    = RQRCode::QRCode.new(text.to_s).qrcode
    size  = qr.module_count
    pad   = [quiet_zone.to_i, 1].max
    total = size + 2 * pad

    # 前景判定：返回该像素是否用亮色块表示
    fg = lambda do |r, c|
      inside = r.between?(pad, pad + size - 1) && c.between?(pad, pad + size - 1)
      dark   = inside && qr.modules[r - pad][c - pad]
      invert ? (inside ? !!dark : false) : (inside ? !dark : true)
    end

    if style.to_sym == :full_block
      (0...total).map { |r|
        (0...total).map { |c| fg.call(r, c) ? "██" : "  " }.join
      }.join("\n")
    else
      (0...total).step(2).map { |r|
        (0...total).map { |c|
          top    = fg.call(r, c)
          bottom = r + 1 < total ? fg.call(r + 1, c) : false
          HALF_BLOCK[top ? 1 : 0][bottom ? 1 : 0]
        }.join
      }.join("\n")
    end
  end
end
