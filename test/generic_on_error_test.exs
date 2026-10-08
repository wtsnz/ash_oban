# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.GenericOnErrorTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshOban.GenericOnErrorTest.Ticket
    end
  end

  defmodule Ticket do
    use Ash.Resource,
      domain: AshOban.GenericOnErrorTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshOban]

    attributes do
      uuid_primary_key :id
      attribute :state, :atom, default: :open, public?: true
      attribute :tenant_id, :string, default: "alpha", public?: true
    end

    multitenancy do
      strategy :attribute
      attribute :tenant_id
      global? true
    end

    oban do
      triggers do
        for {name, callback, fails?, action, mode} <- [
              {:normal, :mark_failed, false, :fail, :fail},
              {:fails_job, :mark_failed, true, :fail, :fail},
              {:atomic, :mark_failed_atomically, false, :fail, :fail},
              {:atomic_paid, :mark_failed_atomically, false, :fail, :pay_fail},
              {:atomic_deleted, :mark_failed_atomically, false, :fail, :delete_fail},
              {:atomic_fails_job, :mark_failed_atomically, true, :fail, :fail},
              {:destroy, :delete_failed, false, :fail, :fail},
              {:handler_fails, :callback_fails, false, :handled_fail, :fail},
              {:handled, :mark_failed, false, :handled_fail, :fail},
              {:snooze, :mark_failed, false, :fail, :snooze},
              {:cancel, :mark_failed, false, :fail, :cancel},
              {:raise, :mark_failed, false, :fail, :raise},
              {:paid, :mark_failed, false, :fail, :pay_fail},
              {:deleted, :mark_failed, false, :fail, :delete_fail},
              {:callback_snooze, :callback_snooze, false, :fail, :fail},
              {:callback_cancel, :callback_cancel, false, :fail, :fail}
            ] do
          trigger name do
            action action
            action_input %{mode: mode}
            on_error callback
            on_error_fails_job? fails?
            where expr(state == :open)
            max_attempts 3
            scheduler_cron false
            log_errors? true
            log_final_error? true
            worker_module_name Module.concat([AshOban.GenericOnErrorTest.Workers, name])
            scheduler_module_name Module.concat([AshOban.GenericOnErrorTest.Schedulers, name])
          end
        end

        trigger :from_record do
          action :fail
          on_error :mark_failed
          where expr(state == :open)
          use_tenant_from_record? true
          max_attempts 3
          scheduler_cron false
          worker_module_name AshOban.GenericOnErrorTest.Workers.FromRecord
          scheduler_module_name AshOban.GenericOnErrorTest.Schedulers.FromRecord
        end

        trigger :default_actor do
          action :fail
          on_error :mark_failed
          where expr(state == :open)
          actor_persister :none
          default_actor %{research_actor: true}
          max_attempts 3
          scheduler_cron false
          worker_module_name AshOban.GenericOnErrorTest.Workers.DefaultActor
          scheduler_module_name AshOban.GenericOnErrorTest.Schedulers.DefaultActor
        end

        trigger :unhandled_final_log do
          action :fail
          max_attempts 3
          scheduler_cron false
          log_errors? false
          log_final_error? true
          worker_module_name AshOban.GenericOnErrorTest.Workers.UnhandledFinalLog
          scheduler_module_name AshOban.GenericOnErrorTest.Schedulers.UnhandledFinalLog
        end

        trigger :quiet do
          action :fail
          on_error :mark_failed
          where expr(state == :open)
          max_attempts 3
          scheduler_cron false
          log_errors? false
          log_final_error? false
          worker_module_name AshOban.GenericOnErrorTest.Workers.Quiet
          scheduler_module_name AshOban.GenericOnErrorTest.Schedulers.Quiet
        end

        trigger :final_log do
          action :fail
          on_error :mark_failed
          where expr(state == :open)
          max_attempts 3
          scheduler_cron false
          log_errors? false
          log_final_error? true
          worker_module_name AshOban.GenericOnErrorTest.Workers.FinalLog
          scheduler_module_name AshOban.GenericOnErrorTest.Schedulers.FinalLog
        end

        trigger :without_where do
          action :fail
          on_error :mark_failed
          max_attempts 3
          scheduler_cron false
          worker_module_name AshOban.GenericOnErrorTest.Workers.WithoutWhere
          scheduler_module_name AshOban.GenericOnErrorTest.Schedulers.WithoutWhere
        end
      end
    end

    actions do
      defaults [:read, :destroy, create: [:tenant_id]]

      update :pay do
        change set_attribute(:state, :paid)
      end

      for name <- [:fail, :handled_fail] do
        action name do
          argument :primary_key, :map, allow_nil?: false
          argument :mode, :atom, default: :fail

          if name == :handled_fail do
            error_handler fn _input, error ->
              send(self(), :generic_error_handler)
              error
            end
          end

          run fn input, _context ->
            send(self(), {:action_actor, input.context.private.actor})

            case input.arguments.mode do
              :raise ->
                raise "original raised"

              :snooze ->
                {:error, AshOban.Errors.SnoozeJob.exception(snooze_for: 17)}

              :cancel ->
                {:error, AshOban.Errors.CancelJob.exception(reason: :requested)}

              :pay_fail ->
                Ash.get!(__MODULE__, input.arguments.primary_key, authorize?: false)
                |> Ash.update!(%{}, action: :pay, authorize?: false)

                {:error, "original failure"}

              :delete_fail ->
                Ash.get!(__MODULE__, input.arguments.primary_key, authorize?: false)
                |> Ash.destroy!(authorize?: false)

                {:error, "original failure"}

              _ ->
                {:error, "original failure"}
            end
          end
        end
      end

      update :mark_failed do
        require_atomic? false
        argument :error, :term

        change fn changeset, context ->
          send(self(), {:callback_actor, context.actor})

          send(
            self(),
            {:on_error, changeset.data.id, changeset.arguments.error,
             context.source_context.ash_oban.job.attempt, context.tenant}
          )

          changeset
        end

        change set_attribute(:state, :failed)
      end

      update :mark_failed_atomically do
        argument :error, :term
        change set_attribute(:state, :failed)
      end

      destroy :delete_failed do
        require_atomic? false
        argument :error, :term
      end

      update :callback_fails do
        require_atomic? false
        argument :error, :term

        change fn changeset, _ ->
          send(self(), :callback_failed)
          Ash.Changeset.add_error(changeset, "callback failure")
        end
      end

      for {name, _error} <- [
            {:callback_snooze, AshOban.Errors.SnoozeJob.exception(snooze_for: 23)},
            {:callback_cancel, AshOban.Errors.CancelJob.exception(reason: :callback_requested)}
          ] do
        update name do
          require_atomic? false
          argument :error, :term

          change fn changeset, _ ->
            Ash.Changeset.add_error(
              changeset,
              if(changeset.action.name == :callback_snooze,
                do: AshOban.Errors.SnoozeJob.exception(snooze_for: 23),
                else: AshOban.Errors.CancelJob.exception(reason: :callback_requested)
              )
            )
          end
        end
      end
    end
  end

  setup do
    Ash.bulk_destroy!(Ticket, :destroy, %{}, authorize?: false)
    ticket = Ash.create!(Ticket, %{}, authorize?: false)
    %{ticket: ticket}
  end

  defp run(ticket, trigger, attempt \\ 3, tenant \\ "alpha") do
    worker = AshOban.Info.oban_trigger(Ticket, trigger).worker

    job = %Oban.Job{
      attempt: attempt,
      max_attempts: 3,
      args: %{"primary_key" => %{"id" => ticket.id}, "tenant" => tenant}
    }

    worker.perform(job)
  end

  defp state(ticket), do: Ash.get!(Ticket, ticket.id, authorize?: false).state

  test "runs the update callback on the last attempt with the error, record and job", %{
    ticket: ticket
  } do
    capture_log(fn -> assert :ok = run(ticket, :normal) end)
    assert state(ticket) == :failed
    assert_received {:on_error, id, %Ash.Error.Unknown{}, 3, "alpha"} when id == ticket.id
  end

  test "earlier attempts fail without running the callback", %{ticket: ticket} do
    log = capture_log(fn -> assert_raise Ash.Error.Unknown, fn -> run(ticket, :normal, 1) end end)
    assert log =~ "original failure"
    assert state(ticket) == :open
    refute_received {:on_error, _, _, _, _}
  end

  test "fails the last attempt after a successful callback when requested", %{ticket: ticket} do
    capture_log(fn -> assert_raise Ash.Error.Unknown, fn -> run(ticket, :fails_job) end end)
    assert state(ticket) == :failed
  end

  test "supports an atomic update callback", %{ticket: ticket} do
    capture_log(fn -> assert :ok = run(ticket, :atomic) end)
    assert state(ticket) == :failed
  end

  test "honors fails_job for atomic callbacks", %{ticket: ticket} do
    capture_log(fn ->
      assert_raise Ash.Error.Unknown, fn -> run(ticket, :atomic_fails_job) end
    end)

    assert state(ticket) == :failed
  end

  test "atomic handlers cancel when the failed action made its record stale", %{ticket: ticket} do
    capture_log(fn ->
      assert {:cancel, :trigger_no_longer_applies} = run(ticket, :atomic_paid)
    end)

    assert state(ticket) == :paid
  end

  test "atomic handlers cancel when the failed action deleted its record", %{ticket: ticket} do
    capture_log(fn ->
      assert {:cancel, :trigger_no_longer_applies} = run(ticket, :atomic_deleted)
    end)
  end

  test "atomic callbacks respect final error logging", %{ticket: ticket} do
    assert capture_log(fn -> assert :ok = run(ticket, :atomic) end) =~ "original failure"
  end

  test "supports a destroy callback", %{ticket: ticket} do
    capture_log(fn -> assert :ok = run(ticket, :destroy) end)
    assert Ash.get(Ticket, ticket.id, authorize?: false, error?: false) == {:ok, nil}
  end

  test "snooze bypasses on_error even on the final attempt", %{ticket: ticket} do
    assert {:snooze, 17} = run(ticket, :snooze)
    refute_received {:on_error, _, _, _, _}
    assert state(ticket) == :open
  end

  test "cancel bypasses on_error even on the final attempt", %{ticket: ticket} do
    assert {:cancel, :requested} = run(ticket, :cancel)
    refute_received {:on_error, _, _, _, _}
  end

  test "rescued exceptions run on_error", %{ticket: ticket} do
    capture_log(fn -> assert :ok = run(ticket, :raise) end)
    assert state(ticket) == :failed
  end

  test "cancels if the record stops matching during the action", %{ticket: ticket} do
    assert {:cancel, :trigger_no_longer_applies} = run(ticket, :paid)
    assert state(ticket) == :paid
    refute_received {:on_error, _, _, _, _}
  end

  test "cancels if the record is deleted during the action", %{ticket: ticket} do
    assert {:cancel, :trigger_no_longer_applies} = run(ticket, :deleted)
    refute_received {:on_error, _, _, _, _}
  end

  test "honors the action's error_handler before running on_error", %{ticket: ticket} do
    capture_log(fn -> assert :ok = run(ticket, :handled) end)
    assert_received :generic_error_handler
    refute_received :generic_error_handler
    assert state(ticket) == :failed
  end

  test "callback failures terminate without reentering the generic error_handler", %{
    ticket: ticket
  } do
    capture_log(fn ->
      assert_raise Ash.Error.Invalid, ~r/callback failure/, fn -> run(ticket, :handler_fails) end
    end)

    assert_received :generic_error_handler
    assert_received :callback_failed
    refute_received :generic_error_handler
    refute_received :callback_failed
    assert state(ticket) == :open
  end

  test "callback snooze is returned to Oban", %{ticket: ticket} do
    capture_log(fn -> assert {:snooze, 23} = run(ticket, :callback_snooze) end)
  end

  test "callback cancel is returned to Oban", %{ticket: ticket} do
    capture_log(fn -> assert {:cancel, :callback_requested} = run(ticket, :callback_cancel) end)
  end

  test "suppresses logs when both flags are false", %{ticket: ticket} do
    assert capture_log(fn -> assert :ok = run(ticket, :quiet) end) == ""
  end

  test "logs only the last attempt when log_errors is false", %{ticket: ticket} do
    assert capture_log(fn ->
             assert_raise Ash.Error.Unknown, fn -> run(ticket, :final_log, 1) end
           end) == ""

    assert capture_log(fn -> assert :ok = run(ticket, :final_log) end) =~ "original failure"
  end

  test "without where still runs on_error for an existing record", %{ticket: ticket} do
    Ash.update!(ticket, %{}, action: :pay, authorize?: false)
    capture_log(fn -> assert :ok = run(ticket, :without_where) end)
    assert state(ticket) == :failed
  end

  test "without a handler logs only the last failed attempt", %{ticket: ticket} do
    assert capture_log(fn ->
             assert_raise Ash.Error.Unknown, fn -> run(ticket, :unhandled_final_log, 1) end
           end) == ""

    assert capture_log(fn ->
             assert_raise Ash.Error.Unknown, fn -> run(ticket, :unhandled_final_log) end
           end) =~ "original failure"
  end

  test "uses a tenant extracted from the record in error handling", %{ticket: ticket} do
    worker = AshOban.Info.oban_trigger(Ticket, :from_record).worker
    job = ticket |> AshOban.build_trigger(:from_record) |> Ecto.Changeset.apply_changes()
    args = job.args |> Jason.encode!() |> Jason.decode!()
    assert args["tenant"] == "alpha"

    capture_log(fn ->
      assert :ok = worker.perform(%{job | args: args, attempt: 3, max_attempts: 3})
    end)

    assert_received {:on_error, _, _, 3, "alpha"}
    assert state(ticket) == :failed
  end

  test "uses the same default actor in the generic action and its handler", %{ticket: ticket} do
    capture_log(fn -> assert :ok = run(ticket, :default_actor) end)
    assert_received {:action_actor, %{research_actor: true}}
    assert_received {:callback_actor, %{research_actor: true}}
  end

  test "uses the job tenant and does not update another tenant's record", %{ticket: ticket} do
    assert {:cancel, :trigger_no_longer_applies} = run(ticket, :normal, 3, "beta")
    assert state(ticket) == :open
    refute_received {:on_error, _, _, _, _}
  end
end
