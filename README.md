# loop.nvim

Workspace and task management for Neovim.

## Features

- **Workspaces** — Project roots marked by `.nvimloop/`. Per-workspace config, variables, and state.
- **Tasks** — Run shell commands or composite workflows. Dependencies run in sequence or parallel.
- **Macros** — `${macro}` substitution in commands (paths, env vars, prompts, workspace variables).
- **UI** — Built-in window for task output and status.
- **Extensions** — Add task types and templates via plugins (e.g. [loop-cmake.nvim](https://github.com/mbfoss/loop-cmake.nvim)).

## Requirements

Neovim >= 0.10

## Installation

**lazy.nvim**
```lua
{
    "mbfoss/loop.nvim",
    event = "VimEnter",
    config = function()
        require("loop").setup({})
    end,
}
```

**packer.nvim**
```lua
use {
    "mbfoss/loop.nvim",
    event = "VimEnter",
    config = function()
        require("loop").setup()
    end,
}
```

Run `:helptags ALL` after installing.

## Quick Start

1. `:Loop workspace create` — Create a workspace in the current directory.
2. `:Loop workspace open` — Open a workspace (or pick from recent).
3. `:Loop task configure` — Edit `tasks.json` to add tasks.
4. `:Loop task run` — Run a task (or `:Loop task run Build` to run by name).
5. `:Loop var configure` — Edit workspace variables.
6. `:Loop ui toggle` — Show or hide the Loop UI.

Workspaces in the current directory are opened automatically on startup.

## Configuration

```lua
require("loop").setup({
    selector = "builtin",   -- or "ui_select"
    autosave_interval = 5,   -- minutes (0 to disable)
    window = {
        symbols = {
            change  = "●",
            success = "✓",
            failure = "✗",
            waiting = "⧗",
            running = "▶",
        },
    },
})
```

## Commands

| Command | Description |
|--------|-------------|
| `:Loop` | Open command selector |
| `:Loop workspace create` | Create workspace |
| `:Loop workspace open` | Open workspace |
| `:Loop workspace close` | Close workspace |
| `:Loop workspace configure` | Edit workspace.json |
| `:Loop workspace save` | Save workspace buffers |
| `:Loop workspace info` | Show workspace info |
| `:Loop task run [name]` | Run task |
| `:Loop task repeat` | Repeat last task |
| `:Loop task configure` | Edit tasks.json |
| `:Loop task terminate` | Stop selected task |
| `:Loop task terminate_all` | Stop all tasks |
| `:Loop var list` | List variables |
| `:Loop var configure` | Edit variables.json |
| `:Loop ui toggle` | Toggle UI |
| `:Loop ui show` | Show UI |
| `:Loop ui hide` | Hide UI |
| `:Loop ui clean` | Remove expired output groups |
| `:Loop page switch` | Switch output page |
| `:Loop page open [group] [page]` | Open specific page |
| `:Loop log` | View plugin logs |

## Task Types

- **process** — Run a shell command.
- **composite** — Run multiple tasks in sequence or parallel.

Example task in `tasks.json`:

```json
{
  "name": "Build",
  "type": "process",
  "command": "make",
  "cwd": "${wsdir}"
}
```

## Macros

Use `${macro}` or `${macro:arg}` in task definitions:

| Macro | Description |
|-------|-------------|
| `${wsdir}` | Workspace root |
| `${cwd}` | Current working directory |
| `${file}` | Current file path |
| `${filename}` | Current filename |
| `${fileroot}` | Path without extension |
| `${filedir}` | Directory of current file |
| `${fileext}` | File extension |
| `${filetype}` | Buffer filetype |
| `${file:lua}` | Path if filetype is `lua`, else fail |
| `${home}` | Home directory |
| `${tmpdir}` | Temp directory |
| `${date}` | Date (YYYY-MM-DD) |
| `${time}` | Time (HH:MM:SS) |
| `${timestamp}` | ISO timestamp |
| `${env:NAME}` | Environment variable |
| `${var:NAME}` | Workspace variable |
| `${prompt:Message}` | Prompt for input |
| `${prompt:Port,8000}` | Prompt with default |

## Statusline

```lua
-- lualine
lualine_c = { function() return require("loop.statusline").status() end, "filename" }
```

## Extensions

- [loop-cmake.nvim](https://github.com/mbfoss/loop-cmake.nvim) — CMake tasks
- [loop-debug.nvim](https://github.com/mbfoss/loop-debug.nvim) — Debug tasks

## Documentation

`:help loop` or [doc/loop.txt](doc/loop.txt)

## License

MIT
