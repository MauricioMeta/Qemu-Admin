defmodule QemuAdmin.SessionTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Session, Settings}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  test "the file is session.json at the root of the workspace; none means the defaults" do
    assert Session.path() == Path.join(Paths.workspace_dir(), "session.json")

    assert %{"view" => "vms", "selected" => nil, "tabs" => [], "views" => %{}, "terminal_open" => true} =
             Session.load()
  end

  test "saves and reads back the tabs, the one on screen and what each shows" do
    session = %{
      "view" => "vms",
      "selected" => "pi3",
      "tabs" => ["pi3", "netduino"],
      "views" => %{"pi3" => "serial", "netduino" => "overview"},
      "terminal_open" => false
    }

    assert :ok = Session.save(session)
    assert Session.load() == session

    # plain JSON, in the order a person reads it
    text = File.read!(Session.path())
    assert String.starts_with?(text, "{\n  \"version\": 1,\n  \"view\": \"vms\"")
  end

  test "what is not valid is dropped, a broken file is the defaults" do
    File.mkdir_p!(Path.dirname(Session.path()))

    File.write!(
      Session.path(),
      ~s({"view": "nada", "selected": 3, "tabs": ["a", 1, "a", "b"], "views": {"a": "log", "b": 7}})
    )

    assert %{"view" => "vms", "selected" => nil, "tabs" => ["a", "b"], "views" => %{"a" => "log"}} =
             Session.load()

    File.write!(Session.path(), "{ não é json")
    assert %{"tabs" => []} = Session.load()
  end
end
