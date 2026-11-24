class WellKnownController < ActionController::Base
  # RFC 9116 — security.txt for vulnerability and abuse reporting
  def security_txt
    contact = OpenNews.config.abuse_contact_email
    canonical = "#{OpenNews.config.app_base_url}/.well-known/security.txt"
    expires = 1.year.from_now.utc.iso8601

    body = <<~TXT
      Contact: mailto:#{contact}
      Expires: #{expires}
      Preferred-Languages: en
      Canonical: #{canonical}
      Policy: #{OpenNews.config.app_base_url}/
    TXT

    response.set_header("Cache-Control", "public, max-age=86400")
    render plain: body, content_type: "text/plain; charset=utf-8"
  end
end
