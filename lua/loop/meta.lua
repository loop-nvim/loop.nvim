--- @meta
error('Cannot require a meta file')

---@class loop.WorkspaceConfig
---@field name string
---@field files {include:string[], exclude:string[],follow_symlinks:boolean}

---@class loop.Task
---@field name string # non-empty task
---@field type "composite"|string # task type
---@field depends_on string[]? # optional list of dependent task names
---@field depends_order "sequence"|"parallel"|nil # default is sequence
---@field save_buffers boolean? # if true, ensures workspace buffers are saved before this task starts
---@field if_running "restart"|"refuse"|"parallel"|nil

---@class loop.taskTemplate
---@field name string
---@field task loop.Task

---@class loop.TaskControl
---@field terminate fun()

---@alias loop.TaskExitHandler fun(success:boolean,reason:string|nil)

---@class loop.ExtensionStorage
---@field get fun(key:string):any
---@field set fun(key:string, value:any)
---@field keys fun():string[]

---@class loop.ViewProvider
---@field create_buffer fun():number

---@class loop.SidebarPreset
---@field views {name:string, ratio:number?}[]

---@class loop.ExtensionAPI
---@field ws_dir string
---@field get_storage fun():loop.ExtensionStorage
---@field get_config_file_path fun(key:string,fileext:string?):string
---@field register_task_type fun(task_type:string, provider:loop.TaskTypeProvider)
---@field register_task_templates fun(category:string, provider:loop.TaskTemplateProvider)
---@field register_user_command fun(lead_cmd:string, provider:loop.UserCommandProvider)
---@field register_view fun(name:string, provider:loop.ViewProvider)
---@field register_sidebar_preset fun(name:string, preset:loop.SidebarPreset)
---@field show_sidebar_preset fun(name:string)
---@field run_process fun(start_args:loop.tools.TermProc.StartArgs):loop.tools.TermProc?,string?

---@class loop.TaskTypeProvider
---@field get_task_schema fun():table
---@field start_one_task fun(task:loop.Task, page_group:loop.PageGroup,on_exit:loop.TaskExitHandler):(loop.TaskControl|nil,string|nil)

---@class loop.TaskTemplateProvider
---@field get_task_templates fun():loop.taskTemplate[]

---@class loop.UserCommandProvider
---@field get_subcommands fun(args:string[]):string[]
---@field dispatch fun(args:string[],opts:vim.api.keyset.create_user_command.command_args)

---@class loop.Extension
---@field on_workspace_load fun(api:loop.ExtensionAPI)
---@field on_workspace_unload fun(api:loop.ExtensionAPI)
---@field on_state_will_save? fun(api:loop.ExtensionAPI)

---@class loop.KeyMap
---@field callback fun()
---@field desc string

---@class loop.CompRenderer
---@field render fun(bufnr:number):boolean -- return true if changed
---@field dispose fun()

---@class loop.BaseBufferController
---@field set_user_data fun(user_data:any)
---@field get_user_data fun():any
---@field add_keymap fun(key:string,keymap:loop.KeyMap)
---@field disable_change_events fun()

---@class loop.OutputBufferController : loop.BaseBufferController
---@field add_lines fun(lines: string|string[])
---@field set_auto_scroll fun(enabled: boolean)
---@field set_max_lines fun(n:number)

---@alias loop.ReplCompletionHandler fun(input:string, callback:fun(suggestions:string[]?,err:string?))

---@class loop.ReplController
---@field set_input_handler fun(handler:fun(input:string))
---@field set_completion_handler fun(handler:loop.ReplCompletionHandler)?
---@field add_output fun(text:string)

---@class loop.PageController
---@field set_ui_flags fun(flags:string)

---@class loop.PageOpts
---@field type "term"|"output"|"repl"
---@field label string
---@field activate boolean?
---@field term_args loop.tools.TermProc.StartArgs?

---@class loop.PageData
---@field page loop.PageController
---@field base_buf loop.BaseBufferController?
---@field output_buf loop.OutputBufferController?
---@field repl_buf loop.ReplController?
---@field term_proc loop.tools.TermProc?

---@class loop.PageGroup
---@field have_pages fun():boolean
---@field add_page fun(opts:loop.PageOpts):loop.PageData?,string?
---@field delete_pages fun()
---@field delete_group fun()
---@field expire fun(delete_pages:boolean?)
---@field is_expired fun():boolean
---@field is_deleted fun():boolean

---@class loop.PageManager
---@field add_page_group fun(label:string):loop.PageGroup|nil
---@field delete_groups fun()
---@field delete_expired_groups fun()
---@field expire fun(delete_groups:boolean)
---@field is_expired fun():boolean
