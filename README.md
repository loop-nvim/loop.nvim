> [!WARNING]
> 🚧 **Work in Progress**
>
> This plugin is currently under active development.
>
> - APIs and configuration may change
> - Breaking changes can occur without notice
>
> Use with caution until a stable release is announced.
> Issues, suggestions, and contributions are welcome while the project evolves.


# loop.nvim

Workspace and task management for Neovim.

## Features

- **Workspaces** — Project roots marked by `.loop/`. Per-workspace config, variables, and state.
- **Tasks** — Run shell commands or composite workflows. Dependencies run in sequence or parallel.
- **Macros** — `${macro}` substitution in commands (paths, env vars, prompts, workspace variables).
- **UI** — Built-in window for task output and status.
- **Extensions** — Add task types, task templates etc... (For Building, Debugging etc...)

## 🎬 Demo Videos (toggle to watch)

<details>
<summary>Workspace Creation</summary>

https://github.com/user-attachments/assets/fbcc9ed7-7a27-4986-8919-4f05f9f29c22

</details>

<details>
<summary>Adding a build task (requires loop-build extension)</summary>

https://github.com/user-attachments/assets/323dc168-01a4-4940-99ec-7c47ab9c59f5

</details>

<details>
<summary>Adding a 'run' task with dependency on the a build task </summary>

https://github.com/user-attachments/assets/f505fb02-6591-4049-97a3-5f34391f17fd

</details>

<details>
<summary>Adding a debug task (requires loop-debug extension)</summary>

https://github.com/user-attachments/assets/606f6a37-0b9d-426f-a89f-e4d1e1375def

</details>


## Requirements

Neovim >= 0.10

## Installation

**lazy.nvim**
```lua
{
    "loop-nvim/loop.nvim",
    lazy = false, -- Loop will lazy load itself
    config = function()
        require("loop").setup({})
    end,
}
```

## Quick Start

1. Create a workspace in the current directory (`:Loop workspace create`). The confiration editor will open.
2. Adjust the configuration as required (`:Loop workspace configure` to reopen the configuration editor)
3. Use `:Loop task configure` to open the task list editor and create new tasks.
4. Use `:Loop task run` to run tasks.
5. Use `:Loop statuspanel` to show or hide the Loop status panel (task output).
5. Use `:Loop sidebar` to show or hide the Loop side bar (file tree or other plugin dependant views).

Workspaces in the current directory are opened automatically on startup when neovim is started without arguments.

## JSON Editor

Workspace config (`workspace.json`), tasks (`tasks.json`), and variables (`variables.json`) are edited in a built-in JSON tree editor with schema validation. Press `g?` inside the editor for help.

| Key | Action |
|-----|--------|
| `<CR>` | Toggle expand/collapse |
| `i` | Add property/item |
| `o` | Add element after |
| `O` | Add element before |
| `c` | Change value |
| `C` | Change value (multiline for strings) |
| `d` | Delete element |
| `u` | Undo |
| `C-r` | Redo |
| `K` | Show schema help for current node |
| `ge` | Show validation errors |
| `g?` | Show keybindings help |

## Configuration

```lua
require("loop").setup({
    workspace_data_dir = ".loop", -- workspace data directory
    state_autosave_interval = 5,   -- minutes (0 to disable)
    statuspanel = {
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

Commands be selected using the command selector by typing `:Loop`


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
| `:Loop statuspanel` | Toggle status panel |
| `:Loop statuspanel show` | Show status panel |
| `:Loop statuspanel hide` | Hide status panel |
| `:Loop statuspanel clean` | Remove old tasks output pages form the status panel |
| `:Loop page switch` | Switch output page |
| `:Loop page open [group] [page]` | Open specific page in the current window |
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

Use `${macro}` or `${macro:args}` in task definitions:

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
| `${var:NAME}` | Workspace variable, use `:Loop var configure` to define variables |
| `${prompt:Message}` | Prompt for input |
| `${prompt:Port,8000}` | Prompt with default |

## User defined macros

Use can define your own macros, example:
```lua
local loop = require('loop')
loop.register_macro('add', function(_, value1, value2)
			local n1 = tonumber(value1) or 0
			local n2 = tonumber(value2) or 0
			return tostring(n1 + n2)
		end)
```
Then it can by used in tasks definitions, for example `${add:1,2}` will be replaced by 3.

## Statusline

```lua
-- lualine
lualine_c = { function() return require("loop.statusline").status() end, "filename" }
```

## Extensions

- [loop-build.nvim](https://github.com/loop-nvim/loop-build.nvim) — Defines a "build" task type and provides templates for various build tasks
- [loop-debug.nvim](https://github.com/loop-nvim/loop-debug.nvim) — Defines a "debug" task type and provides templates for various debug tasks
- [loop-cmake.nvim](https://github.com/loop-nvim/loop-cmake.nvim) — Provides task templates generated automatically from CMake files
- [loop-marks.nvim](https://github.com/loop-nvim/loop-marks.nvim) - Workspace based named bookmarks and notes


## License

MIT
