class ApplicationController < ActionController::Base
  SESSION_COOKIE = :open_news_session

  before_action :resume_session

  helper_method :current_user, :signed_in?

  private

  def resume_session
    raw = cookies.signed[SESSION_COOKIE]
    return if raw.blank?

    sess = Session.includes(:user).find_by_raw_token(raw)
    if sess&.user&.active?
      Current.session = sess
    else
      cookies.delete(SESSION_COOKIE)
    end
  end

  def current_user
    Current.user
  end

  def signed_in?
    current_user.present?
  end

  def require_authentication
    return if signed_in?

    session[:return_to] = request.fullpath if request.get?
    redirect_to login_path, alert: "Please sign in to continue."
  end

  def sign_in(user)
    sess = Session.issue_for(user, ip_address: request.remote_ip, user_agent: request.user_agent)
    Current.session = sess
    cookies.signed[SESSION_COOKIE] = {
      value: sess.raw_token,
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production? || request.ssl?,
      expires: 30.days.from_now
    }
  end

  def sign_out
    Current.session&.destroy
    Current.session = nil
    cookies.delete(SESSION_COOKIE)
  end

  def safe_return_path
    path = session.delete(:return_to).to_s
    return dashboard_path unless path.start_with?("/") && !path.start_with?("//")

    path
  end
end
