defmodule SymphonyElixir.AgentAdaptersTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentAdapter
  alias SymphonyElixir.Agents.{ClaudeCode, Pi, ToolBridge}

  defp issue(labels \\ []) do
    %Issue{
      id: "issue-agent-#{System.unique_integer([:positive])}",
      identifier: "MT-AGENT",
      title: "Agent adapter",
      description: "Exercise agent adapters",
      state: "In Progress",
      url: "https://example.org/issues/MT-AGENT",
      labels: labels
    }
  end

  defp tmp_root(name) do
    root = Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp write_script!(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp collect_messages do
    parent = self()
    fn message -> send(parent, {:agent_message, message}) end
  end

  defp received_events do
    receive_all([]) |> Enum.map(& &1.event)
  end

  defp receive_all(acc) do
    receive do
      {:agent_message, message} -> receive_all([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "adapter selection" do
    test "defaults to codex" do
      assert AgentAdapter.kind_for_issue(issue()) == "codex"
      assert AgentAdapter.for_issue(issue()) == SymphonyElixir.Agents.Codex
    end

    test "uses agent.kind and lets labels override it" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        agent_kind_by_label: %{"Agent: Pi" => "pi", "codex" => "codex"}
      )

      assert AgentAdapter.for_issue(issue(["backend"])) == ClaudeCode
      assert AgentAdapter.for_issue(issue(["agent: pi"])) == Pi
      assert AgentAdapter.for_issue(issue([" CODEX "])) == SymphonyElixir.Agents.Codex
      assert AgentAdapter.for_issue(%{labels: nil}) == ClaudeCode
      assert map_size(AgentAdapter.adapters()) == 3
    end

    test "rejects unknown kinds" do
      assert_raise ArgumentError, fn -> AgentAdapter.adapter_for_kind!("gemini") end

      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "gemini")
      assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

      write_workflow_file!(Workflow.workflow_file_path(), agent_kind_by_label: %{"x" => "gemini"})
      assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()
    end
  end

  describe "tool bridge" do
    test "registers sessions with a configured URL and executes tools by token" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_tool_bridge_url: "http://imac.local:4000/")

      registration = ToolBridge.register(issue(), "macbook")

      assert registration.env["SYMPHONY_TOOL_URL"] == "http://imac.local:4000/api/v1/agent_tools"
      assert registration.env["SYMPHONY_TOOL_TOKEN"] == registration.token
      assert registration.preface =~ "linear_graphql"
      assert registration.preface =~ "$SYMPHONY_TOOL_TOKEN"

      assert {:ok, %{"success" => false}} = ToolBridge.execute(registration.token, "linear_graphql", %{})
      assert {:error, :unauthorized} = ToolBridge.execute("unknown", "linear_graphql", %{})
      assert {:error, :unauthorized} = ToolBridge.execute(nil, "linear_graphql", %{})

      assert :ok = ToolBridge.unregister(registration.token)
      assert :ok = ToolBridge.unregister(nil)
      assert {:error, :unauthorized} = ToolBridge.execute(registration.token, "linear_graphql", %{})
    end

    test "offers no tools when there is no reachable URL" do
      log =
        capture_log(fn ->
          assert %{env: env, preface: ""} = ToolBridge.register(issue(), "macbook")
          assert env == %{}
          assert %{env: %{}, preface: ""} = ToolBridge.register(issue(), nil)
        end)

      assert log =~ "tool bridge unavailable"
      assert ToolBridge.preface([]) == ""
    end
  end

  describe "Claude Code adapter" do
    test "runs continuation turns in one process, tracks usage and hides tracker secrets" do
      root = tmp_root("claude-adapter")
      workspace_root = Path.join(root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE")
      File.mkdir_p!(workspace)
      trace = Path.join(root, "trace")

      claude =
        write_script!(root, "fake-claude", """
        #!/bin/sh
        printf 'linear=%s tool=%s\\n' "${LINEAR_API_KEY:-unset}" "${SYMPHONY_TOOL_URL:-none}" > #{trace}
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\\n' "$line" >> #{trace}
          echo 'not json'
          printf '%s\\n' '{"type":"system","subtype":"init","session_id":"s1"}'
          printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
          printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":10,"cache_read_input_tokens":5,"output_tokens":3}}'
        done
        """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude",
        agent_tool_bridge_url: "http://127.0.0.1:4999",
        claude_command: claude
      )

      previous = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "secret")

      try do
        assert {:ok, session} = ClaudeCode.start_session(workspace, issue: issue())
        on_message = collect_messages()
        assert {:ok, %{session_id: first_id}} = ClaudeCode.run_turn(session, "first prompt", issue(), on_message: on_message)
        assert {:ok, %{session_id: second_id}} = ClaudeCode.run_turn(session, "second prompt", issue(), on_message: on_message)
        assert first_id != second_id
        assert :ok = ClaudeCode.stop_session(session)

        messages = receive_all([])
        completed = Enum.filter(messages, &(&1.event == :turn_completed))
        assert [%{usage: %{"total_tokens" => 18}}, %{usage: %{"total_tokens" => 36}}] = completed
        assert Enum.count(messages, &(&1.event == :session_started)) == 2

        trace_lines = trace |> File.read!() |> String.split("\n", trim: true)
        assert hd(trace_lines) == "linear=unset tool=http://127.0.0.1:4999/api/v1/agent_tools"
        [first, second] = trace_lines |> tl() |> Enum.map(&Jason.decode!/1)
        assert [%{"text" => first_text}] = first["message"]["content"]
        assert first_text =~ "Tracker tools"
        assert first_text =~ "first prompt"
        assert [%{"text" => "second prompt"}] = second["message"]["content"]
      after
        restore_env("LINEAR_API_KEY", previous)
        File.rm_rf(root)
      end
    end

    test "reports failed results, process exits and timeouts" do
      root = tmp_root("claude-adapter-errors")
      workspace = Path.join([root, "workspaces", "MT-CLAUDE-ERR"])
      File.mkdir_p!(workspace)

      failing =
        write_script!(root, "fake-claude-fail", """
        #!/bin/sh
        read -r _line
        printf '%s\\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"usage":{}}'
        read -r _line
        exit 3
        """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(root, "workspaces"),
        claude_command: failing
      )

      try do
        capture_log(fn ->
          assert {:ok, session} = ClaudeCode.start_session(workspace, [])
          on_message = collect_messages()
          assert {:error, {:turn_failed, %{"subtype" => "error_max_turns"}}} = ClaudeCode.run_turn(session, "go", issue(), on_message: on_message)
          assert {:error, {:port_exit, 3}} = ClaudeCode.run_turn(session, "again", issue(), on_message: on_message)
          ClaudeCode.stop_session(session)
          assert :turn_failed in received_events()
        end)

        silent = write_script!(root, "fake-claude-silent", "#!/bin/sh\nsleep 5\n")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.join(root, "workspaces"),
          claude_command: silent,
          claude_turn_timeout_ms: 100
        )

        capture_log(fn ->
          assert {:ok, session} = ClaudeCode.start_session(workspace, [])
          assert {:error, :turn_timeout} = ClaudeCode.run_turn(session, "go", %{}, [])
          ClaudeCode.stop_session(session)
        end)

        assert {:error, {:invalid_workspace_cwd, _, _, _}} = ClaudeCode.start_session(root, [])
      after
        File.rm_rf(root)
      end
    end
  end

  describe "pi adapter" do
    test "runs prompts until agent_end, cancels dialogs and tracks usage" do
      root = tmp_root("pi-adapter")
      workspace_root = Path.join(root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PI")
      File.mkdir_p!(workspace)
      trace = Path.join(root, "trace")

      pi =
        write_script!(root, "fake-pi", """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\\n' "$line" >> #{trace}
          case "$count" in
            1)
              printf '%s\\n' '{"type":"response","command":"prompt","success":true,"id":"symphony-turn-1"}'
              printf '%s\\n' '{"type":"response","command":"get_state","success":false,"error":"ignored"}'
              printf '%s\\n' '{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Sure?"}'
              ;;
            2)
              printf '%s\\n' 'garbage'
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"agent_end","messages":[{"role":"user"},{"role":"assistant","usage":{"input":7,"cacheRead":3,"output":2},"stopReason":"stop"}]}'
              ;;
            3)
              printf '%s\\n' '{"type":"agent_end","messages":"bad"}'
              ;;
          esac
        done
        """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        pi_command: pi
      )

      try do
        capture_log(fn ->
          assert {:ok, session} = Pi.start_session(workspace, issue: issue())
          on_message = collect_messages()
          assert {:ok, %{turn_id: "1"}} = Pi.run_turn(session, "first prompt", issue(), on_message: on_message)
          assert {:ok, %{turn_id: "2"}} = Pi.run_turn(session, "second prompt", issue(), on_message: on_message)
          Pi.stop_session(session)

          completed = receive_all([]) |> Enum.filter(&(&1.event == :turn_completed))
          assert [%{usage: %{"total_tokens" => 12}}, %{usage: %{"total_tokens" => 12}}] = completed
        end)

        [prompt, ui_response, second] = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
        assert %{"type" => "prompt", "id" => "symphony-turn-1", "message" => "first prompt"} = prompt
        assert %{"type" => "extension_ui_response", "id" => "ui-1", "cancelled" => true} = ui_response
        assert %{"type" => "prompt", "message" => "second prompt"} = second
      after
        File.rm_rf(root)
      end
    end

    test "reports rejected prompts, errored runs, exits and timeouts" do
      root = tmp_root("pi-adapter-errors")
      workspace = Path.join([root, "workspaces", "MT-PI-ERR"])
      File.mkdir_p!(workspace)

      pi =
        write_script!(root, "fake-pi-errors", """
        #!/bin/sh
        read -r _line
        printf '%s\\n' '{"type":"response","command":"prompt","success":false,"error":"busy"}'
        read -r _line
        printf '%s\\n' '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"rate limited"}]}'
        read -r _line
        printf '%s\\n' '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error"}]}'
        read -r _line
        exit 4
        """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(root, "workspaces"),
        pi_command: pi
      )

      try do
        capture_log(fn ->
          assert {:ok, session} = Pi.start_session(workspace, [])
          assert {:error, {:prompt_rejected, "busy"}} = Pi.run_turn(session, "a", issue(), [])
          assert {:error, {:turn_failed, "rate limited"}} = Pi.run_turn(session, "b", issue(), [])
          assert {:error, {:turn_failed, "pi agent stopped with an error"}} = Pi.run_turn(session, "c", %{}, [])
          assert {:error, {:port_exit, 4}} = Pi.run_turn(session, "d", issue(), [])
          Pi.stop_session(session)
        end)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: Path.join(root, "workspaces"),
          pi_command: write_script!(root, "fake-pi-silent", "#!/bin/sh\nsleep 5\n"),
          pi_turn_timeout_ms: 100
        )

        capture_log(fn ->
          assert {:ok, session} = Pi.start_session(workspace, [])
          assert {:error, :turn_timeout} = Pi.run_turn(session, "go", issue(), [])
          Pi.stop_session(session)
        end)

        assert {:error, {:invalid_workspace_cwd, _, _, _}} = Pi.start_session(root, [])
      after
        File.rm_rf(root)
      end
    end
  end
end
