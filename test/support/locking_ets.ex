# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.Test.LockingEts do
  @moduledoc false
  # ETS, but reporting that it can transact and lock `:for_update`, so tests can
  # reach the code paths AshOban uses for such data layers. Transactions only
  # track nesting and rollback; locks do nothing.
  use Spark.Dsl.Extension, sections: []

  @behaviour Ash.DataLayer

  @ets Ash.DataLayer.Ets
  @key {__MODULE__, :in_transaction?}
  @own [can?: 2, transaction: 4, in_transaction?: 1, rollback: 2, lock: 3]

  Code.ensure_compiled!(@ets)

  for {name, arity} <- Ash.DataLayer.behaviour_info(:callbacks),
      {name, arity} not in @own,
      function_exported?(@ets, name, arity) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(name)(unquote_splicing(args)), do: @ets.unquote(name)(unquote_splicing(args))
  end

  @impl true
  def can?(_, :transact), do: true
  def can?(_, {:lock, :for_update}), do: true
  def can?(resource, feature), do: @ets.can?(resource, feature)

  @impl true
  def lock(query, _lock_type, _resource), do: {:ok, query}

  @impl true
  def in_transaction?(_resource), do: Process.get(@key, false)

  @impl true
  def rollback(_resource, value), do: throw({@key, :rollback, value})

  @impl true
  def transaction(_resource, fun, _timeout, _reason) do
    if Process.get(@key) do
      {:ok, fun.()}
    else
      Process.put(@key, true)

      try do
        {:ok, fun.()}
      catch
        {@key, :rollback, value} -> {:error, value}
      after
        Process.delete(@key)
      end
    end
  end
end
