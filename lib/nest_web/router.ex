defmodule NestWeb.Router do
  use NestWeb, :router

  alias NestWeb.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NestWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # /api/v1 — JSON API surface for authentication.
  # The `FetchCurrentUser` plug runs first so every
  # downstream handler sees `conn.assigns.current_user`.
  # Invite CRUD is channel-only (see `LobbyChannel`'s
  # `create_invite` / `revoke_invite` handlers); logout is
  # client-only (no server state to clear in v1).
  pipeline :api_v1 do
    plug :accepts, ["json"]
    plug Auth.FetchCurrentUser
  end

  scope "/", NestWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Public auth endpoints (login, register) — no auth
  # required. Logout is intentionally not here: the server
  # has no session to clear in v1.
  scope "/api/v1", NestWeb do
    pipe_through :api_v1

    post "/login", AuthController, :login
    post "/register", AuthController, :register
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:nest, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NestWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Catch-all route for React Router - must be last
  scope "/", NestWeb do
    pipe_through :browser

    get "/*path", PageController, :home
  end
end
