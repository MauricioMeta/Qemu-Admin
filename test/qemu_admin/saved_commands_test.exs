defmodule QemuAdmin.SavedCommandsTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Qemu, Settings, VmServer, VmStore}
  alias QemuAdmin.Terminal.{Macro, Saved}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  defp attrs(extra \\ %{}) do
    Map.merge(%{"name" => "start", "description" => "liga", "steps" => "@start\ninfo status"}, extra)
  end

  describe "the file" do
    test "is terminal.json at the root of the workspace; no file, no commands" do
      assert Saved.path() == Path.join(Paths.workspace_dir(), "terminal.json")
      assert {:ok, []} = Saved.load()
      assert Saved.list("qualquer") == []
    end

    test "saves, lists by name and deletes" do
      {:ok, a} = Saved.validate(attrs(%{"name" => "zeta"}))
      {:ok, b} = Saved.validate(attrs(%{"name" => "Alfa"}))
      assert :ok = Saved.save(a)
      assert :ok = Saved.save(b)

      assert ["Alfa", "zeta"] = Enum.map(Saved.list("x"), & &1["name"])
      assert File.regular?(Saved.path())

      # it is plain JSON, made to be edited by hand
      assert %{"version" => 1, "commands" => [%{"name" => "Alfa", "steps" => ["@start", "info status"]} | _]} =
               Saved.path() |> File.read!() |> Jason.decode!()

      assert :ok = Saved.delete("alfa")
      assert ["zeta"] = Enum.map(Saved.list("x"), & &1["name"])
    end

    test "a name is not taken twice; an edit may rename" do
      {:ok, a} = Saved.validate(attrs())
      assert :ok = Saved.save(a)
      assert {:error, "já existe" <> _} = Saved.save(a)

      {:ok, renamed} = Saved.validate(attrs(%{"name" => "ligar", "steps" => "cont"}))
      assert :ok = Saved.save(renamed, "start")
      assert ["ligar"] = Enum.map(Saved.list("x"), & &1["name"])

      {:ok, other} = Saved.validate(attrs(%{"name" => "outro"}))
      assert :ok = Saved.save(other)
      assert {:error, "já existe" <> _} = Saved.save(renamed, "outro")
    end

    test "a command for one VM exists only for it" do
      {:ok, all} = Saved.validate(attrs(%{"name" => "todas"}))
      {:ok, one} = Saved.validate(attrs(%{"name" => "so-esta", "vm" => "vm-a"}))
      Saved.save(all)
      Saved.save(one)

      assert ["so-esta", "todas"] = Enum.map(Saved.list("vm-a"), & &1["name"])
      assert ["todas"] = Enum.map(Saved.list("vm-b"), & &1["name"])
      assert {:ok, %{"name" => "so-esta"}} = Saved.find(" SO-ESTA ", "vm-a")
      assert :error = Saved.find("so-esta", "vm-b")
      assert :error = Saved.find("start status", "vm-a")
    end

    test "a hand-written file is read as it is, tolerating what is not a command" do
      File.mkdir_p!(Paths.workspace_dir())

      File.write!(Saved.path(), """
      {"commands": [
        {"name": "status", "steps": ["info status", "", "# um comentário", "info cpus"]},
        {"name": "semsteps"},
        "lixo",
        {"name": "para-vm", "vm": "x", "steps": ["stop"], "continue_on_error": true}
      ]}
      """)

      assert [%{"name" => "para-vm", "continue_on_error" => true}, %{"name" => "status"} = s] =
               Saved.list("x")

      assert s["steps"] == ["info status", "info cpus"]
      assert s["vm"] == nil and s["description"] == "" and s["continue_on_error"] == false
    end

    test "a file that is not JSON is an error, and is never overwritten" do
      File.mkdir_p!(Paths.workspace_dir())
      File.write!(Saved.path(), "{ isto não é json")

      assert {:error, "terminal.json não é um JSON válido" <> _} = Saved.load()
      assert Saved.list("x") == []

      {:ok, c} = Saved.validate(attrs())
      assert {:error, msg} = Saved.save(c)
      assert msg =~ "corrija ou apague"
      assert File.read!(Saved.path()) == "{ isto não é json"
    end
  end

  describe "validate/1" do
    test "name: one word" do
      for bad <- ["", "dois nomes", "-comeca", "com/barra", String.duplicate("a", 41)] do
        assert {:error, "o nome deve ser" <> _} = Saved.validate(attrs(%{"name" => bad})), bad
      end

      for good <- ["start", "Start1", "liga.vm_2", "a-b"] do
        assert {:ok, _} = Saved.validate(attrs(%{"name" => good})), good
      end
    end

    test "steps: at least one, and the app's own are only @start and @wait N" do
      assert {:error, "dê pelo menos um passo"} = Saved.validate(attrs(%{"steps" => "\n# nada\n"}))
      assert {:error, "passo inválido: @voar"} = Saved.validate(attrs(%{"steps" => "info status\n@voar"}))
      assert {:error, "passo inválido: @wait x"} = Saved.validate(attrs(%{"steps" => "@wait x"}))
      assert {:ok, %{"steps" => ["@start", "@wait 2", "info status"]}} =
               Saved.validate(attrs(%{"steps" => "@start\n\n@wait 2\n  info status  "}))
    end

    test "the rest is normalized" do
      assert {:ok, c} = Saved.validate(attrs(%{"vm" => "", "continue_on_error" => "on"}))
      assert c["vm"] == nil and c["continue_on_error"] == true
      assert {:ok, %{"vm" => "abc"}} = Saved.validate(attrs(%{"vm" => "abc"}))
    end
  end

  describe "Macro (tools only: no VM needed)" do
    @describetag :qemu

    setup do
      {:ok, vm} = VmStore.create(%{"name" => "Macro VM", "arch" => "x86_64", "machine" => "q35"})
      %{vm: vm}
    end

    defp texts(id, dir), do: for(e <- VmServer.commands(id), e.dir == dir, do: e.text)

    test "runs the steps in order, with the VM's name and folder in them", %{vm: vm} do
      if Qemu.available?() do
        command = %{
          "name" => "disco",
          "steps" => ["qemu-img create -f qcow2 {vm}.qcow2 4M", "@wait 0", "qemu-img info {vm}.qcow2"],
          "continue_on_error" => false
        }

        assert :ok = Macro.run(vm.id, command)
        assert File.regular?(Path.join(QemuAdmin.Vm.dir(vm), "#{vm.id}.qcow2"))

        assert ["disco — 3 passos", "disco — concluído"] = texts(vm.id, "macro")
        assert ["qemu-img create -f qcow2 macro-vm.qcow2 4M", "qemu-img info macro-vm.qcow2"] = texts(vm.id, "tool")
        assert Enum.any?(texts(vm.id, "received"), &(&1 =~ "virtual size: 4 MiB"))
      end
    end

    test "stops at the first step that fails; continue_on_error goes on", %{vm: vm} do
      if Qemu.available?() do
        steps = ["qemu-img info nao-existe.img", "qemu-img --version"]

        assert {:error, 1} = Macro.run(vm.id, %{"name" => "falha", "steps" => steps})
        assert Enum.any?(texts(vm.id, "error"), &(&1 =~ "passo 1 falhou"))
        assert List.last(texts(vm.id, "macro")) == "falha — interrompido no passo 1 de 2"
        assert ["qemu-img info nao-existe.img"] = texts(vm.id, "tool")

        assert :ok = Macro.run(vm.id, %{"name" => "segue", "steps" => steps, "continue_on_error" => true})
        assert List.last(texts(vm.id, "macro")) == "segue — concluído"
        assert "qemu-img --version" in texts(vm.id, "tool")
      end
    end

    test "a monitor step with the VM off is an error that stops the run", %{vm: vm} do
      assert {:error, 1} = Macro.run(vm.id, %{"name" => "monitor", "steps" => ["info status", "qemu-img --version"]})
      assert Enum.any?(texts(vm.id, "error"), &(&1 =~ "a VM está desligada"))
    end

    test "expand/2 fills in the placeholders", %{vm: vm} do
      assert Macro.expand("{vm}|{name}|{dir}", vm) == "#{vm.id}|Macro VM|#{QemuAdmin.Vm.dir(vm)}"
    end
  end

  describe "Macro with the VM" do
    @describetag :qemu
    @describetag timeout: 90_000

    test "@start turns it on, the steps talk to it, and @start again changes nothing" do
      if "x86_64" in Qemu.info().emulators do
        {:ok, vm} =
          VmStore.create(%{
            "name" => "liga",
            "arch" => "x86_64",
            "machine" => "q35",
            "memory" => "64",
            "display" => "none",
            "accel" => "tcg"
          })

        command = %{"name" => "start", "steps" => ["@start", "info status", "@start", "quit"]}
        assert :ok = Macro.run(vm.id, command)

        history = VmServer.commands(vm.id) |> Enum.map(&{&1.dir, &1.text})
        assert {"received", "VM ligada"} in history
        assert {"received", "VM status: running"} in history
        assert {"received", "a VM já está ligada"} in history
        assert {"macro", "start — concluído"} in history

        # what was logged with the VM off (the header, `@start`) survives the launch
        header = Enum.find_index(history, &(&1 == {"macro", "start — 4 passos"}))
        launch = Enum.find_index(history, &match?({"launch", _}, &1))
        assert header < launch

        # `quit` was the last step: let QEMU go before the folder is removed
        Enum.reduce_while(1..100, nil, fn _, _ ->
          if QemuAdmin.VmSupervisor.running?(vm.id),
            do: (Process.sleep(100) && {:cont, nil}),
            else: {:halt, nil}
        end)
      end
    end
  end
end
