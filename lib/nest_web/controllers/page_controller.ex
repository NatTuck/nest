defmodule NestWeb.PageController do
  use NestWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
