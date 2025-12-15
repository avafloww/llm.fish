# llm.fish

Translate natural language to shell commands using Claude.

**Simplicity is the point.** One file, no dependencies beyond Claude Code, no configuration files, no package managers. Just copy and go.

If you want something fancier, there are other tools for that.

## Installation

```bash
curl -sL https://raw.githubusercontent.com/avafloww/llm.fish/refs/heads/main/llm.fish -o ~/.config/fish/functions/llm.fish
```

Requires [Claude Code](https://github.com/anthropics/claude-code) CLI.

## Usage

```bash
llm list all docker containers
llm find large files in this directory
llm --yolo show disk usage
```

## Options

- `--model <model>` — Use `sonnet`, `opus`, or `haiku`
- `--yolo` — Execute immediately, no confirmation
- `--no-yolo` — Just print the command
- `--set-default <key> <value>` — Persist settings (`model`, `yolo`)
- `--help` — Show help

## Modes

**Interactive** (default): Shows the command with a menu to execute, cancel, or refine.

**Non-interactive**: When piped, outputs the raw command only.

**Yolo**: `--yolo` runs the command immediately without asking.

## Defaults

```bash
llm --set-default model sonnet  # default
llm --set-default yolo off      # default
```

Stored as Fish universal variables.

## License

[WTFPL](LICENSE)
