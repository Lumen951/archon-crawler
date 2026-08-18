require "faraday"
require "faraday/multipart"
require "stringio"
require "json"
require "digest"
require "openssl"
require "base64"

# 飞书（Feishu）推送客户端。
#
# 通过自建应用机器人（app_id + app_secret）发送消息到私聊（open_id）或群（chat_id）。
# 发送二维码图片需要先上传拿到 image_key（im/v1/images），再发 image 消息。
#
# 配置（Option）:
#   feishu_app_id / feishu_app_secret  自建应用凭据
#   feishu_receive_id                  推送目标：私聊 open_id 或群 chat_id
#   feishu_receive_id_type             "open_id"（默认）或 "chat_id"
#
class FeishuNotifier
  # 注意：BASE_URL 只写 origin，路径前缀 /open-apis 放到每个请求里。
  # 若把 /open-apis 写进 BASE_URL，再以 "/..." 开头的路径发请求，Faraday 会把
  # base path 整个丢弃（把 "/..." 当作从根开始的绝对路径），导致 404。
  BASE_URL = "https://open.feishu.cn"

  class Error < StandardError; end

  # 配置齐全才算启用
  def self.enabled?
    Option.feishu_enabled? &&
      Option.feishu_app_id.present? &&
      Option.feishu_app_secret.present? &&
      Option.feishu_receive_id.present?
  end

  # 获取 tenant_access_token（缓存约 1 小时，token 有效期约 2 小时）
  def self.tenant_access_token
    Rails.cache.fetch("feishu:tenant_access_token", expires_in: 1.hour) do
      resp = connection.post("/open-apis/auth/v3/tenant_access_token/internal") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = {
          app_id: Option.feishu_app_id,
          app_secret: Option.feishu_app_secret
        }.to_json
      end

      data = parse_body(resp)
      data["tenant_access_token"] || raise(Error, "获取 tenant_access_token 失败: #{data.inspect}")
    end
  rescue Faraday::Error => e
    raise Error, "飞书连接失败: #{e.message}"
  end

  # 上传图片，返回 image_key
  def self.upload_image(png_bytes)
    # FilePart 第一个参数是文件路径或 IO；传裸字节需包一层 StringIO，否则会被当成路径去 open
    file = Faraday::Multipart::FilePart.new(StringIO.new(png_bytes), "image/png", "qr.png")
    payload = {
      image_type: "message",
      image: file
    }

    resp = connection.post("/open-apis/im/v1/images") do |req|
      req.headers["Authorization"] = "Bearer #{tenant_access_token}"
      req.body = payload
    end

    data = parse_body(resp)
    data.dig("data", "image_key") || raise(Error, "上传图片失败: #{data.inspect}")
  rescue Faraday::Error => e
    raise Error, "飞书连接失败: #{e.message}"
  end

  # 发送一条二维码图片 + 一条文字说明
  def self.send_qr_login(png_bytes:, text:, receive_id: nil, receive_id_type: nil)
    image_key = upload_image(png_bytes)
    send_image(image_key, receive_id: receive_id, receive_id_type: receive_id_type)
    send_text(text, receive_id: receive_id, receive_id_type: receive_id_type)
  end

  # 私聊发送二维码 + 文字给指定 open_id
  def self.send_qr_login_to(open_id:, png_bytes:, text:)
    send_qr_login(png_bytes: png_bytes, text: text, receive_id: open_id, receive_id_type: "open_id")
  end

  # 发送图片消息
  def self.send_image(image_key, receive_id: nil, receive_id_type: nil)
    send_message(msg_type: "image", content: { image_key: image_key }.to_json, receive_id: receive_id, receive_id_type: receive_id_type)
  end

  # 发送文字消息
  def self.send_text(text, receive_id: nil, receive_id_type: nil)
    send_message(msg_type: "text", content: { text: text }.to_json, receive_id: receive_id, receive_id_type: receive_id_type)
  end

  # 发送交互式消息卡片（msg_type = interactive，content 为卡片 JSON）
  def self.send_card(card, receive_id: nil, receive_id_type: nil)
    send_message(msg_type: "interactive", content: card.to_json, receive_id: receive_id, receive_id_type: receive_id_type)
  end

  def self.send_message(msg_type:, content:, receive_id: nil, receive_id_type: nil)
    receive_id_type = receive_id_type.presence || Option.feishu_receive_id_type.presence || "open_id"
    receive_id = receive_id.presence || Option.feishu_receive_id

    # receive_id_type 是必填的 query 参数（不是 body），必须拼到 URL 上
    resp = connection.post("/open-apis/im/v1/messages?receive_id_type=#{receive_id_type}") do |req|
      req.headers["Authorization"] = "Bearer #{tenant_access_token}"
      req.headers["Content-Type"] = "application/json"
      req.body = {
        receive_id: receive_id,
        msg_type: msg_type,
        content: content
      }.to_json
    end

    parse_body(resp)
  rescue Faraday::Error => e
    raise Error, "飞书连接失败: #{e.message}"
  end

  # 校验飞书卡片回调签名。
  #
  # 算法（官方文档）：signature = sha256(timestamp + nonce + encrypt_key + 请求体) 的 hexdigest，
  # 与请求头 X-Lark-Signature 比对。encrypt_key 未配置时跳过验签（仅记录告警日志）。
  def self.verify_signature?(timestamp:, nonce:, signature:, body:)
    encrypt_key = Option.feishu_encrypt_key.to_s
    if encrypt_key.empty?
      Rails.logger.warn("[Feishu] 未配置 encrypt_key，跳过回调验签")
      return true
    end

    # 对原始字节做拼接与摘要，避免编码不兼容（body 可能含中文）
    expected = Digest::SHA256.hexdigest("#{timestamp}#{nonce}#{encrypt_key}".b + body.to_s.b)
    return true if expected == signature.to_s

    Rails.logger.warn(
      "[Feishu] 回调签名不匹配（timestamp=#{timestamp.present?}, nonce=#{nonce.present?}, " \
      "signature=#{signature.present?}）。请确认 feishu_encrypt_key 是飞书后台「事件与回调 → 加密策略」" \
      "里的 Encrypt Key，而非验证令牌（Verification Token）。"
    )
    false
  end

  # 解密飞书加密回调。
  #
  # 飞书开启加密策略后，回调 body 形如 {"encrypt": "<base64>"}。encrypt 字段为
  # base64(AES-256-CBC(iv(16 字节) + 密文))，key = SHA256(encrypt_key)，iv 取解码后前 16 字节，
  # PKCS7 填充。返回解密后的明文字符串（通常为 JSON）。
  def self.decrypt_callback(encrypt)
    encrypt_key = Option.feishu_encrypt_key.to_s
    raise Error, "已收到加密回调但未配置 feishu_encrypt_key" if encrypt_key.empty?

    data = Base64.decode64(encrypt)
    raise Error, "非法密文长度" if data.bytesize <= 16 || data.bytesize % 16 != 0

    key = Digest::SHA256.digest(encrypt_key)
    iv = data.byteslice(0, 16)
    ciphertext = data.byteslice(16, data.bytesize - 16)

    decipher = OpenSSL::Cipher.new("AES-256-CBC")
    decipher.decrypt
    decipher.key = key
    decipher.iv = iv
    plain = decipher.update(ciphertext) + decipher.final

    plain.force_encoding(Encoding::UTF_8)
  rescue OpenSSL::Cipher::CipherError => e
    raise Error, "回调解密失败（feishu_encrypt_key 可能不正确）: #{e.message}"
  end

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      # 只保留 multipart：JSON 请求 body 是字符串（multipart 会原样透传），
      # 上传图片 body 是含 FilePart 的 Hash（multipart 会正确编码）。
      # 不能加 url_encoded —— 它会把上传的 Hash 先 url 编码，把 FilePart 变成字符串。
      f.request :multipart
      f.options.timeout = 20
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end
  private_class_method :connection

  def self.parse_body(resp)
    body = resp.body.to_s
    data = JSON.parse(body) rescue {}

    unless resp.status >= 200 && resp.status < 300 && data["code"].to_i == 0
      raise Error, "飞书 API 错误 (HTTP #{resp.status}, code=#{data['code']}): #{data['msg'] || body[0..200]}"
    end

    data
  end
  private_class_method :parse_body
end
