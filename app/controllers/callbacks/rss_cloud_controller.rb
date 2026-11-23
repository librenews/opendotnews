module Callbacks
  class RssCloudController < ActionController::Base
    skip_forgery_protection

    # GET /callbacks/rsscloud/:token — rssCloud challenge verification
    def verify
      res = RssCloud::Consumer.verify_challenge(raw_token: params[:token], params: request.query_parameters)
      render plain: res.body, content_type: res.content_type, status: res.http_status
    end

    # POST /callbacks/rsscloud/:token — rssCloud REST form POST or XML-RPC ping
    def notify
      res = RssCloud::Consumer.receive_ping(
        raw_token: params[:token],
        raw_body: request.raw_post,
        params: request.request_parameters,
        content_type: request.content_type
      )
      render plain: res.body, content_type: res.content_type, status: res.http_status
    end
  end
end
