# ex_pi

`ex_pi` is an Elixir port of the [earendil-works/pi](https://github.com/earendil-works/pi) coding agent. This project is a study port designed to understand the architectural choices of `pi` while leveraging the strengths of the Erlang VM (BEAM), such as concurrency, fault tolerance, and real-time process communication.

## Architecture

`ex_pi` is built as an Elixir umbrella project consisting of five core applications:

- **`ex_pi_ai`**: A unified interface for multiple LLM providers (Anthropic, OpenAI). It features a pure SSE reducer for side-effect-free protocol parsing.
- **`ex_pi_agent`**: The core agent loop implemented as a `GenServer` per session. It manages conversational state, internal reasoning (thoughts), and context transformation.
- **`ex_pi_session`**: A durable, append-only persistence layer using JSONL. It supports history replay, time-travel branching (forking), and context compaction.
- **`ex_pi_coding`**: A robust tool system (read, edit, bash) with a concurrent dispatcher. It includes built-in security boundaries and real-time output streaming via Elixir `Port`s.
- **`ex_pi_web`**: A modern web interface built with Phoenix LiveView. It provides real-time token streaming, session management, and interactive permission handling.

## Key Features

- **Unified AI Interface**: Seamlessly switch between providers using a flattened `ExPiAi.Message` protocol.
- **Rich Agent Logic**: Support for internal "thinking" blocks, metadata, and message redaction.
- **Durable Sessions**: Every state change is persisted to an append-only log, ensuring seamless crash recovery.
- **Non-Linear History**: Fork any session at any point to explore alternative solutions without losing context.
- **Safe Tool Execution**: Tools are execution-isolated and path-restricted, with a mandatory human-in-the-loop permission system for sensitive actions.
- **Reactive UI**: Real-time updates via Phoenix PubSub and LiveView, providing a low-latency, "alive" experience.

## Getting Started

### Prerequisites

- Elixir 1.18 or later
- Erlang/OTP 27
- An API key for Anthropic or OpenAI

### Installation

1.  Clone the repository:
    ```bash
    git clone https://github.com/gsmlg-dev/ex_pi.git
    cd ex_pi
    ```

2.  Install dependencies:
    ```bash
    mix deps.get
    ```

3.  Configure your API keys:
    ```bash
    export ANTHROPIC_AUTH_TOKEN="your_key_here"
    # OR
    export OPENROUTER_API_KEY="your_key_here"
    ```

4.  Start the Phoenix server:
    ```bash
    mix phx.server
    ```

Now you can visit [`localhost:4580`](http://localhost:4580) from your browser.

## Usage

- **Start a Session**: Navigate to `/sessions/default` or enter a new session ID.
- **Interact**: Type your prompts in the chat box. The agent will stream tokens back to you in real-time.
- **Manage Sessions**: Use the sidebar to list existing sessions or fork the current session into a new branch.
- **Grant Permissions**: When the agent attempts a restricted action (like a bash command), a modal will appear for you to allow or deny the execution.

## Development

- **Run Tests**: `mix test`
- **Check Formatting**: `mix format --check-formatted`
- **Compile with Warnings as Errors**: `mix compile --warnings-as-errors`

## License

This project is licensed under the same terms as the original `pi` project.
