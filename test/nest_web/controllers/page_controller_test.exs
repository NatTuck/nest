defmodule NestWeb.PageControllerTest do
  use NestWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(<div id="root" class="h-screen"></div>)
  end
end
