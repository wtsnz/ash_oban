# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.GenericActionWhereTest do
  use ExUnit.Case, async: false

  use AshOban.Test, repo: AshOban.Test.Repo, prefix: "private"

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshOban.GenericActionWhereTest.Ticket
    end
  end

  defmodule Ticket do
    use Ash.Resource,
      domain: AshOban.GenericActionWhereTest.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshOban]

    oban do
      triggers do
        trigger :remind do
          action :remind
          where expr(state == :open)
          scheduler_cron false
          queue :triggered_generic_action_where
          worker_module_name AshOban.GenericActionWhereTest.Ticket.Worker.Remind
          scheduler_module_name AshOban.GenericActionWhereTest.Ticket.Scheduler.Remind
        end

        trigger :remind_handled do
          action :remind_handled
          where expr(state == :open)
          scheduler_cron false
          queue :triggered_generic_action_where
          worker_module_name AshOban.GenericActionWhereTest.Ticket.Worker.RemindHandled
          scheduler_module_name AshOban.GenericActionWhereTest.Ticket.Scheduler.RemindHandled
        end

        trigger :remind_always do
          action :remind
          scheduler_cron false
          queue :triggered_generic_action_where
          worker_module_name AshOban.GenericActionWhereTest.Ticket.Worker.RemindAlways
          scheduler_module_name AshOban.GenericActionWhereTest.Ticket.Scheduler.RemindAlways
        end
      end
    end

    attributes do
      uuid_primary_key :id

      attribute :state, :atom,
        constraints: [one_of: [:open, :paid]],
        default: :open,
        allow_nil?: false,
        public?: true
    end

    actions do
      defaults [:read, :destroy, create: []]

      update :pay do
        change set_attribute(:state, :paid)
      end

      action :remind do
        argument :primary_key, :map, allow_nil?: false

        run fn input, _ ->
          send(AshOban.GenericActionWhereTest, {:reminded, input.arguments.primary_key["id"]})
          :ok
        end
      end

      # An error handler sees errors added to the input, so the cancellation
      # mustn't be one.
      action :remind_handled do
        argument :primary_key, :map, allow_nil?: false
        error_handler fn _input, _error -> "handled" end

        run fn input, _ ->
          send(AshOban.GenericActionWhereTest, {:reminded, input.arguments.primary_key["id"]})
          :ok
        end
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
    Process.register(self(), __MODULE__)
    :ok
  end

  defp run(ticket, trigger) do
    AshOban.run_trigger(ticket, trigger)
    Oban.drain_queue(queue: :triggered_generic_action_where)
  end

  defp pay(ticket), do: Ash.update!(ticket, %{}, action: :pay, authorize?: false)

  describe "a generic action trigger" do
    test "runs for a record that still matches its `where`" do
      ticket = Ash.create!(Ticket, %{}, authorize?: false)

      assert %{success: 1} = run(ticket, :remind)
      assert_received {:reminded, id} when id == ticket.id
    end

    test "is cancelled for a record that no longer matches its `where`" do
      ticket = Ash.create!(Ticket, %{}, authorize?: false)
      AshOban.run_trigger(ticket, :remind)
      pay(ticket)

      assert %{cancelled: 1} = Oban.drain_queue(queue: :triggered_generic_action_where)
      refute_received {:reminded, _}
    end

    test "is cancelled when the action has an error handler" do
      ticket = Ash.create!(Ticket, %{}, authorize?: false)
      AshOban.run_trigger(ticket, :remind_handled)
      pay(ticket)

      assert %{cancelled: 1} = Oban.drain_queue(queue: :triggered_generic_action_where)
      refute_received {:reminded, _}
    end

    test "without a `where` runs whatever the record's state" do
      ticket = Ash.create!(Ticket, %{}, authorize?: false)
      AshOban.run_trigger(ticket, :remind_always)
      pay(ticket)

      assert %{success: 1} = Oban.drain_queue(queue: :triggered_generic_action_where)
      assert_received {:reminded, id} when id == ticket.id
    end
  end
end
