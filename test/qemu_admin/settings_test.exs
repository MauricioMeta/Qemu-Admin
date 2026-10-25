defmodule QemuAdmin.SettingsTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Settings}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> Settings.reset() end)
    :ok
  end

  test "defaults, then what the form sends, cast and saved" do
    assert Settings.get(:default_accel) == "auto"

    Settings.put(%{"default_accel" => "tcg", "stop_timeout" => "45", "confirm_close" => "false"})
    assert Settings.get(:default_accel) == "tcg"
    assert Settings.get(:stop_timeout) == 45
    assert Settings.get(:confirm_close) == false

    saved = Paths.settings_file() |> File.read!() |> Jason.decode!()
    assert saved["stop_timeout"] == 45
  end

  test "bad values fall back to the default; numbers are clamped" do
    Settings.put(%{"default_accel" => "turbo", "stop_timeout" => "9999", "nonsense" => "x"})
    assert Settings.get(:default_accel) == "auto"
    assert Settings.get(:stop_timeout) == 600
    refute Map.has_key?(Settings.all(), :nonsense)
  end
end
