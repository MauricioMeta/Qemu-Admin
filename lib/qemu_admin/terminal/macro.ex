defmodule QemuAdmin.Terminal.Macro do
  @moduledoc """
  Runs a saved command (`QemuAdmin.Terminal.Saved`) on a VM: its steps, in
  order, each as if typed in the Terminal (`QemuAdmin.Terminal.execute/2`), so
  everything shows in the VM's history — a `macro` line (`▶`) that opens the run
  and another that closes it, and the steps in between.

  It stops at the first step that fails unless the command has
  `continue_on_error`. Two steps are the app's own:

    * `@start` — turns the VM on and waits (up to 30 s) until QEMU runs it;
      nothing happens if it is on already;
    * `@wait N` — waits N seconds (up to 120).

  `{vm}`, `{name}` and `{dir}` in a step are the VM's id, name and folder.
  Meant to run in a process of its own (the page uses `start_async`): it blocks
  until the last step is done.
  """

  alias QemuAdmin.{Terminal, Vm, VmStore, VmSupervisor}

  @start_timeout 30_000
  @max_wait 120

  @doc "`:ok` when every step worked (or was allowed to fail), `{:error, step_number}` at the one that stopped it."
  def run(vm_id, command) do
    case VmStore.get(vm_id) do
      {:ok, vm} -> run_steps(vm, command)
      _ -> {:error, 0}
    end
  end

  defp run_steps(vm, %{"name" => name, "steps" => steps} = command) do
    total = length(steps)
    Terminal.log(vm.id, "macro", "#{name} — #{total} #{if total == 1, do: "passo", else: "passos"}")

    result =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {step, n}, :ok ->
        line = expand(step, vm)

        case step(vm, line) do
          :ok ->
            {:cont, :ok}

          :error ->
            if command["continue_on_error"] == true do
              Terminal.log(vm.id, "error", "passo #{n} falhou; seguindo (continue_on_error)")
              {:cont, :ok}
            else
              Terminal.log(vm.id, "error", "passo #{n} falhou: #{line}")
              {:halt, {:error, n}}
            end
        end
      end)

    Terminal.log(
      vm.id,
      "macro",
      case result do
        :ok -> "#{name} — concluído"
        {:error, n} -> "#{name} — interrompido no passo #{n} de #{total}"
      end
    )

    result
  end

  @doc "A step with `{vm}`, `{name}` and `{dir}` replaced."
  def expand(step, %Vm{} = vm) do
    step
    |> String.replace("{vm}", vm.id)
    |> String.replace("{name}", vm.name)
    |> String.replace("{dir}", Vm.dir(vm))
  end

  defp step(vm, "@start"), do: start(vm)

  defp step(vm, "@wait " <> n) do
    case Integer.parse(String.trim(n)) do
      {secs, ""} when secs >= 0 ->
        Terminal.log(vm.id, "typed", "@wait #{secs}")
        Process.sleep(min(secs, @max_wait) * 1000)
        :ok

      _ ->
        Terminal.log(vm.id, "error", "@wait espera um número de segundos")
        :error
    end
  end

  defp step(vm, line), do: Terminal.execute(vm, line)

  defp start(vm) do
    Terminal.log(vm.id, "typed", "@start")

    if VmSupervisor.running?(vm.id) do
      Terminal.log(vm.id, "received", "a VM já está ligada")
      :ok
    else
      with {:ok, _pid} <- VmSupervisor.start_vm(vm),
           :ok <- wait_running(vm.id, System.monotonic_time(:millisecond) + @start_timeout) do
        Terminal.log(vm.id, "received", "VM ligada")
        :ok
      else
        {:error, msg} when is_binary(msg) ->
          Terminal.log(vm.id, "error", msg)
          :error

        _ ->
          Terminal.log(vm.id, "error", "a VM não chegou a ligar")
          :error
      end
    end
  end

  # `running` is when QMP answers: from then on the monitor and QMP steps work
  defp wait_running(id, deadline) do
    case VmSupervisor.runtime(id).status do
      status when status in [:running, :paused] ->
        :ok

      :stopped ->
        {:error, "a VM desligou logo depois de ligar (veja a aba Log)"}

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, "a VM demorou mais de #{div(@start_timeout, 1000)} s para ligar"}
        else
          Process.sleep(100)
          wait_running(id, deadline)
        end
    end
  end
end
