defmodule NestWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  # `Phoenix.Controller.render/3` renders an error through
  # `Phoenix.Template.render_to_string/4`, so this is the production entry point.
  import Phoenix.Template, only: [render_to_string: 4]

  # One test covers both statuses: `render/2` is a single delegation to
  # `status_message_from_template/1` with no branch of its own. Both literals
  # stay because neither status stands in for the other — a hardcoded
  # "Not Found" would pass the 404 alone, and the library's `rescue` clause
  # returns "Internal Server Error" for any template it cannot parse.
  test "renders an error template as its status message" do
    assert render_to_string(NestWeb.ErrorHTML, "404", "html", []) == "Not Found"
    assert render_to_string(NestWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
