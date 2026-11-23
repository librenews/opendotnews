Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self
    policy.img_src     :self, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self
    policy.frame_ancestors :none
    policy.base_uri    :self
  end
end
