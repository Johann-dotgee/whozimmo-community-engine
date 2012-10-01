require 'omniauth-facebook'
require 'omniauth-linkedin'
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :developer unless Rails.env.production?
  provider :facebook, "", ""
  provider :linkedin, "pn3l5xv6epxr", "kW3SZDkVZoAL4XBW"
end