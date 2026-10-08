# SPDX-FileCopyrightText: 2023 ash_oban contributors <https://github.com/ash-project/ash_oban/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshOban.DescriptionTest do
  use ExUnit.Case, async: true

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshOban.DescriptionTest.Described
    end
  end

  defmodule Described do
    use Ash.Resource,
      domain: AshOban.DescriptionTest.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshOban]

    oban do
      triggers do
        trigger :process do
          description "Processes unprocessed records."
          action :process
          where expr(processed != true)
          scheduler_cron false
          worker_module_name AshOban.DescriptionTest.Described.Worker.Process
          scheduler_module_name AshOban.DescriptionTest.Described.Scheduler.Process
        end
      end

      scheduled_actions do
        schedule :nightly, "0 0 * * *" do
          description "Does nothing, nightly."
          action :nothing
          worker_module_name AshOban.DescriptionTest.Described.ActionWorker.Nightly
        end
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :processed, :boolean, default: false, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read]

      update :process do
        change set_attribute(:processed, true)
      end

      action :nothing do
        run fn _, _ -> :ok end
      end
    end
  end

  test "triggers and scheduled actions have a description" do
    assert %{description: "Processes unprocessed records."} =
             AshOban.Info.oban_trigger(Described, :process)

    assert [%{description: "Does nothing, nightly."}] =
             AshOban.Info.oban_scheduled_actions(Described)
  end
end
