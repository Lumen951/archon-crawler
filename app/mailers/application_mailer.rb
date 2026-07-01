class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "no-reply@mp-crawler.miracleplus.com")
  layout "mailer"
end
