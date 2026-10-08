# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.Verifiers.VerifyOnError do
  @moduledoc "Checks that a trigger's `on_error` action is an update or destroy action."
  use Spark.Dsl.Verifier

  def verify(dsl) do
    module = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    dsl
    |> AshOban.Info.oban_triggers()
    |> Enum.filter(& &1.on_error)
    |> Enum.find_value(:ok, fn trigger ->
      on_error = Ash.Resource.Info.action(dsl, trigger.on_error)

      if on_error && on_error.type not in [:update, :destroy] do
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:oban, :triggers, trigger.name, :on_error],
           message: "The `on_error` action must be an update or destroy action."
         )}
      end
    end)
  end
end
