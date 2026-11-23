class WebSubHubController < ActionController::Base
  skip_forgery_protection

  # POST /websub/hub — W3C WebSub downstream subscription control
  def handle
    res = WebSub::Hub.handle_request(params: request.request_parameters, verify_async: true)
    if res.ok?
      head :accepted
    else
      render plain: res.error, content_type: "text/plain; charset=utf-8", status: res.http_status
    end
  end
end
