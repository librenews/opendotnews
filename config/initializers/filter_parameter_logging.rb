# Filter sensitive credentials and user document bodies from routine application logs.
Rails.application.config.filter_parameters += [
  :passw, :password, :password_confirmation, :email, :secret, :token,
  :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :authorization, :code, :code_verifier, :markdown, :opml_xml
]
