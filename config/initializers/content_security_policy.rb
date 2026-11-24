# Strict Content-Security-Policy preventing arbitrary script execution across UI and rendered public Markdown.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :none
    policy.object_src  :none
    policy.base_uri    :none
    policy.frame_ancestors :none
    policy.form_action :self
    policy.img_src     :self, :https, :data
    policy.style_src   :self, :unsafe_inline
  end
end

Rails.application.config.action_dispatch.default_headers.merge!(
  "X-Content-Type-Options" => "nosniff",
  "Referrer-Policy" => "strict-origin-when-cross-origin",
  "Permissions-Policy" => "geolocation=(), microphone=(), camera=()"
)
