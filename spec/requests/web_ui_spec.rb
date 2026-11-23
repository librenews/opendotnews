require "rails_helper"

RSpec.describe "Minimal Web UI and Account Lifecycle", type: :request do
  it "rejects reserved namespaces, registers a valid user, renders dashboard, and revokes OAuth connections" do
    post "/signup", params: {
      user: { email: "bad@example.org", namespace: "admin", password: "password123!", password_confirmation: "password123!" }
    }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("is reserved")

    post "/signup", params: {
      user: { email: "matt@example.org", namespace: "Matt", password: "password123!", password_confirmation: "password123!" }
    }
    expect(response).to redirect_to("/dashboard")

    user = User.find_by!(email: "matt@example.org")
    expect(user.namespace).to eq("matt")
    expect(user.default_publication).to be_present

    get "/dashboard"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("@matt")

    # Export OPML via signed-in session
    get "/opml/export"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<opml")

    # Create an OAuth token, view connections page, revoke it
    app = Doorkeeper::Application.create!(name: "Nods", redirect_uri: "http://127.0.0.1/cb", scopes: "feeds:read", confidential: false)
    tok = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: "feeds:read", expires_in: 3600)

    get "/settings/connections"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Nods")

    delete "/settings/connections/#{tok.id}"
    expect(response).to redirect_to("/settings/connections")
    expect(tok.reload).to be_revoked
  end
end
