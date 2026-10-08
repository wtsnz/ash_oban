# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.GenericOnErrorLockTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshOban.GenericOnErrorLockTest.Ticket
    end
  end

  defmodule Race do
    use Ash.Resource.Change

    def change(changeset, _, _) do
      if Process.get(:onerror_race) do
        Ash.update!(changeset.data, %{}, action: :pay, authorize?: false)
      end

      changeset
    end
  end

  defmodule Ticket do
    use Ash.Resource,
      domain: AshOban.GenericOnErrorLockTest.Domain,
      data_layer: AshOban.Test.LockingEts,
      extensions: [AshOban]

    attributes do
      uuid_primary_key :id
      attribute :state, :atom, default: :open
    end

    oban do
      triggers do
        for {name, action} <- [{:normal, :fail}, {:transactional, :fail_transactionally}] do
          trigger name do
            action action
            on_error :mark_failed
            where expr(state == :open)
            max_attempts 1
            scheduler_cron false
            worker_module_name Module.concat([AshOban.GenericOnErrorLockTest.Workers, name])
            scheduler_module_name Module.concat([AshOban.GenericOnErrorLockTest.Schedulers, name])
          end
        end
      end
    end

    actions do
      defaults [:read, :destroy, create: []]

      update :pay do
        change set_attribute(:state, :paid)
      end

      action :fail do
        argument :primary_key, :map
        run fn _, _ -> {:error, "original failure"} end
      end

      action :fail_transactionally do
        transaction? true
        argument :primary_key, :map
        run fn _, _ -> {:error, "original failure"} end
      end

      update :mark_failed do
        require_atomic? false
        argument :error, :term
        change AshOban.GenericOnErrorLockTest.Race

        change before_action(
                 fn changeset, _ ->
                   send(
                     self(),
                     {:callback_hook, Ash.DataLayer.in_transaction?(__MODULE__),
                      changeset.data.state}
                   )

                   changeset
                 end,
                 prepend?: true
               )

        change set_attribute(:state, :failed)
      end
    end
  end

  setup do
    Ash.bulk_destroy!(Ticket, :destroy, %{}, authorize?: false)
    %{ticket: Ash.create!(Ticket, %{}, authorize?: false)}
  end

  defp run(ticket, trigger) do
    worker = AshOban.Info.oban_trigger(Ticket, trigger).worker

    worker.perform(%Oban.Job{
      attempt: 1,
      max_attempts: 1,
      args: %{"primary_key" => %{"id" => ticket.id}}
    })
  end

  test "runs a callback with locks held inside its transaction", %{ticket: ticket} do
    capture_log(fn -> assert :ok = run(ticket, :normal) end)
    assert_received {:callback_hook, true, :open}
    assert Ash.get!(Ticket, ticket.id, authorize?: false).state == :failed
  end

  test "cancels a record changed while the callback changeset is built", %{ticket: ticket} do
    Process.put(:onerror_race, true)
    capture_log(fn -> assert {:cancel, :trigger_no_longer_applies} = run(ticket, :normal) end)
    assert Ash.get!(Ticket, ticket.id, authorize?: false).state == :paid
  end

  test "rechecks before the callback's prepended hook", %{ticket: ticket} do
    Process.put(:onerror_race, true)
    capture_log(fn -> assert {:cancel, :trigger_no_longer_applies} = run(ticket, :normal) end)
    refute_received {:callback_hook, _, _}
  end

  test "locks error handling independently of the original action transaction", %{ticket: ticket} do
    Process.put(:onerror_race, true)

    capture_log(fn ->
      assert {:cancel, :trigger_no_longer_applies} = run(ticket, :transactional)
    end)

    assert Ash.get!(Ticket, ticket.id, authorize?: false).state == :paid
    refute_received {:callback_hook, _, _}
  end
end
