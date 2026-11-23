module Callbacks
  class WebSubController < ActionController::Base
    skip_forgery_protection

    # GET /callbacks/websub/:token — W3C WebSub Verification of Intent
    def verify
      res = WebSub::Subscriber.verify_intent(raw_token: params[:token], params: request.query_parameters)
      render plain: res.body, content_type: res.content_type, status: res.http_status
    end

    # POST /callbacks/websub/:token — W3C WebSub Content Distribution
    def notify
      headers = {
        "content-type" => request.content_type,
        "x-hub-signature" => request.headers["X-Hub-Signature"],
        "link" => request.headers["Link"],
        "etag" => request.headers["ETag"],
        "last-modified" => request.headers["Last-Modified"]
      }.compact

      res = WebSub::Subscriber.receive_distribution(
        raw_token: params[:token],
        raw_body: request.raw_post,
        headers: headers
      )
      render plain: res.body, content_type: res.content_type, status: res.http_status
    end
  end
end
