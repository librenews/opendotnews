class RssCloudServerController < ActionController::Base
  skip_forgery_protection

  # POST /rsscloud/pleaseNotify — REST registration
  def please_notify
    res = RssCloud::Cloud.register_rest(params: request.request_parameters, remote_ip: request.remote_ip)
    render plain: res.body, content_type: res.content_type, status: res.http_status
  end

  # POST /rsscloud/RPC2 — XML-RPC registration
  def rpc2
    res = RssCloud::Cloud.register_xmlrpc(raw_xml: request.raw_post, remote_ip: request.remote_ip)
    render plain: res.body, content_type: res.content_type, status: res.http_status
  end

  # POST /rsscloud/ping — guarded hosted-feed ping
  def ping
    url = request.request_parameters["url"].presence || params[:url]
    res = RssCloud::Cloud.ping(raw_topic_url: url)
    render plain: res.body, content_type: res.content_type, status: res.http_status
  end
end
