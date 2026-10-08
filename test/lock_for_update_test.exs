# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.LockForUpdateTest do
  use ExUnit.Case, async: false

  use AshOban.Test, repo: AshOban.Test.Repo, prefix: "private"

  import ExUnit.CaptureLog

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshOban.LockForUpdateTest.Ticket
    end
  end

  defmodule PayBeforeTransaction do
    @moduledoc false
    # Pays the ticket while the changeset is built: after the worker has read the
    # record, and before the action's transaction starts.
    use Ash.Resource.Change

    def change(changeset, _, _) do
      if :persistent_term.get({__MODULE__, :enabled?}, false) do
        Ash.update!(changeset.data, %{}, action: :pay, authorize?: false)
      end

      changeset
    end
  end

  defmodule Ticket do
    use Ash.Resource,
      domain: AshOban.LockForUpdateTest.TestDomain,
      data_layer: AshOban.Test.LockingEts,
      extensions: [AshOban]

    oban do
      triggers do
        trigger :close do
          action :close
          where expr(state == :open)
          scheduler_cron false
          queue :triggered_lock_for_update_close
          worker_module_name AshOban.LockForUpdateTest.Ticket.Worker.Close
          scheduler_module_name AshOban.LockForUpdateTest.Ticket.Scheduler.Close
        end

        trigger :close_with_prepended_hook do
          action :close_with_prepended_hook
          where expr(state == :open)
          scheduler_cron false
          queue :triggered_lock_for_update_close
          worker_module_name AshOban.LockForUpdateTest.Ticket.Worker.CloseWithPrependedHook
          scheduler_module_name AshOban.LockForUpdateTest.Ticket.Scheduler.CloseWithPrependedHook
        end

        trigger :fail_atomically do
          action :fail_atomically
          where expr(state == :open)
          on_error :mark_failed
          max_attempts 1
          scheduler_cron false
          queue :triggered_lock_for_update_close
          worker_module_name AshOban.LockForUpdateTest.Ticket.Worker.FailAtomically
          scheduler_module_name AshOban.LockForUpdateTest.Ticket.Scheduler.FailAtomically
        end

        trigger :fail_to_close do
          action :fail
          where expr(state == :open)
          on_error :mark_failed
          max_attempts 1
          scheduler_cron false
          queue :triggered_lock_for_update_close
          worker_module_name AshOban.LockForUpdateTest.Ticket.Worker.FailToClose
          scheduler_module_name AshOban.LockForUpdateTest.Ticket.Scheduler.FailToClose
        end
      end
    end

    attributes do
      uuid_primary_key :id

      attribute :state, :atom,
        constraints: [one_of: [:open, :paid, :closed, :failed, :never]],
        default: :open,
        allow_nil?: false,
        public?: true
    end

    actions do
      defaults [:read, :destroy, create: []]

      update :pay do
        change set_attribute(:state, :paid)
      end

      update :close do
        require_atomic? false
        change PayBeforeTransaction
        change set_attribute(:state, :closed)
      end

      # Its own prepended hook must still run after the trigger's re-read.
      update :close_with_prepended_hook do
        require_atomic? false
        change PayBeforeTransaction

        change before_action(
                 fn changeset, _ ->
                   send(self(), {:hook_ran, changeset.data.state})
                   changeset
                 end,
                 prepend?: true
               )

        change set_attribute(:state, :closed)
      end

      update :fail_atomically do
        validate attribute_equals(:state, :never)
      end

      update :fail do
        require_atomic? false

        change before_action(fn changeset, _ ->
                 Ash.Changeset.add_error(changeset, "always fails")
               end)
      end

      update :mark_failed do
        require_atomic? false
        argument :error, :term
        change PayBeforeTransaction
        change set_attribute(:state, :failed)
      end
    end
  end

  setup_all do
    AshOban.Test.Repo.start_link()
    Oban.start_link(AshOban.config([TestDomain], Application.get_env(:ash_oban, :oban)))
    :ok
  end

  setup do
    Oban.delete_all_jobs(Oban.Job)
    Ash.bulk_destroy!(Ticket, :destroy, %{}, authorize?: false)
    on_exit(fn -> :persistent_term.erase({PayBeforeTransaction, :enabled?}) end)
  end

  defp stored_state(ticket), do: Ash.get!(Ticket, ticket.id, authorize?: false).state

  defp run(ticket, trigger) do
    AshOban.run_trigger(ticket, trigger)
    Oban.drain_queue(queue: :triggered_lock_for_update_close)
  end

  test "closes a ticket that still matches the trigger" do
    ticket = Ash.create!(Ticket, %{}, authorize?: false)

    assert %{success: 1} = run(ticket, :close)
    assert stored_state(ticket) == :closed
  end

  test "re-checks `where` inside the action's transaction, and cancels the job if it no longer matches" do
    ticket = Ash.create!(Ticket, %{}, authorize?: false)
    :persistent_term.put({PayBeforeTransaction, :enabled?}, true)

    assert %{cancelled: 1} = run(ticket, :close)
    assert stored_state(ticket) == :paid
  end

  test "re-checks `where` inside the on_error action's transaction" do
    ticket = Ash.create!(Ticket, %{}, authorize?: false)
    :persistent_term.put({PayBeforeTransaction, :enabled?}, true)

    capture_log(fn -> assert %{cancelled: 1} = run(ticket, :fail_to_close) end)

    assert stored_state(ticket) == :paid
  end

  test "re-checks `where` before the action's own prepended hooks" do
    ticket = Ash.create!(Ticket, %{}, authorize?: false)
    :persistent_term.put({PayBeforeTransaction, :enabled?}, true)

    assert %{cancelled: 1} = run(ticket, :close_with_prepended_hook)
    refute_received {:hook_ran, _}
    assert stored_state(ticket) == :paid
  end

  test "re-checks `where` for a non-atomic on_error action after an atomic action fails" do
    ticket = Ash.create!(Ticket, %{}, authorize?: false)
    :persistent_term.put({PayBeforeTransaction, :enabled?}, true)

    capture_log(fn -> assert %{cancelled: 1} = run(ticket, :fail_atomically) end)
    assert stored_state(ticket) == :paid
  end
end
