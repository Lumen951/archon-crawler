# frozen_string_literal: true

require "test_helper"

class QrAsciiTest < ActiveSupport::TestCase
  URL = "https://weread.111965.xyz/scan?x=1"

  test "renders a non-empty multi-line string" do
    art = QrAscii.render(URL)
    assert art.is_a?(String)
    assert art.lines.count > 1
    assert art.strip.present?
  end

  test "half_block style has expected dimensions and charset" do
    size  = RQRCode::QRCode.new(URL).qrcode.module_count
    width = size + 4 # quiet_zone = 2

    art = QrAscii.render(URL, style: :half_block)
    lines = art.lines(chomp: true)

    assert_equal width, lines.first.length
    assert_equal (width + 1) / 2, lines.length
    assert_empty art.delete("\n").delete(" ").delete("▀").delete("▄").delete("█")
  end

  test "full_block style has expected dimensions and charset" do
    size  = RQRCode::QRCode.new(URL).qrcode.module_count
    width = 2 * (size + 4)

    art = QrAscii.render(URL, style: :full_block)
    lines = art.lines(chomp: true)

    assert_equal width, lines.first.length
    assert_equal size + 4, lines.length
    assert_empty art.delete("\n").delete("█").delete(" ")
  end

  test "invert produces a different (complemented) rendering" do
    normal = QrAscii.render(URL)
    inverted = QrAscii.render(URL, invert: true)

    assert_equal normal.length, inverted.length
    refute_equal normal, inverted
  end

  test "default dark-terminal polarity renders quiet zone as bright foreground" do
    art = QrAscii.render(URL, style: :full_block)
    lines = art.lines(chomp: true)

    # 外圈静区在深色终端下应全部为亮色前景 "█"
    assert_equal "██", lines.first[0, 2]
    assert_equal "██", lines.first[-2, 2]
    assert_equal "██", lines.last[0, 2]
    assert_equal "██", lines.last[-2, 2]
  end
end
