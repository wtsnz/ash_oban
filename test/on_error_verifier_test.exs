# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.OnErrorVerifierTest do
  use ExUnit.Case, async: false

  defp compile(action, callback) do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")
    callback_option = if callback, do: "on_error #{inspect(callback)}", else: ""

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Ash.Resource, domain: AshOban.Test.Domain, data_layer: Ash.DataLayer.Ets,
        extensions: [AshOban]
      attributes do
        uuid_primary_key :id
      end
      actions do
        defaults [:read, :create, :update, :destroy]
        action :generic do
          argument :primary_key, :map
          run fn _, _ -> :ok end
        end
      end
      oban do
        triggers do
          trigger :test do
            action #{inspect(action)}
            #{callback_option}
            scheduler_cron false
            worker_module_name __MODULE__.Worker
            scheduler_module_name __MODULE__.Scheduler
          end
        end
      end
    end
    """)
  end

  test "rejects unsupported callback types" do
    for callback <- [:read, :create, :generic] do
      assert_raise Spark.Error.DslError, ~r/must be an update or destroy/, fn ->
        compile(:generic, callback)
      end
    end
  end

  test "accepts update and destroy handlers for generic triggers" do
    assert [_ | _] = compile(:generic, :update)
    assert [_ | _] = compile(:generic, :destroy)
  end

  test "accepts generic triggers without on_error" do
    assert [_ | _] = compile(:generic, nil)
  end

  test "accepts update and destroy handlers for record actions" do
    assert [_ | _] = compile(:update, :update)
    assert [_ | _] = compile(:update, :destroy)
  end
end
