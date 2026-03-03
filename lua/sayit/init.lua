--- Retrieves a selection of lines from the current Neovim buffer.
---
--- @param opts vim.api.keyset.create_user_command.command_args Optional table of options.
--- @return table A list of strings, where each string represents a line from the buffer.
local function get_selection(args)
    local bufnr = vim.api.nvim_get_current_buf()
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    -- If range is provided (defaults to current line if range=true)
    if args.line1 and args.line2 then
        return vim.api.nvim_buf_get_lines(bufnr, args.line1 - 1, args.line2, false)
    end

    return {}
end

-- use this function to check if all the executables are available
local function check_executables(names)
    for _, name in ipairs(names) do
        if vim.fn.executable(name) ~= 1 then
            vim.notify(name .. " not found", vim.log.levels.ERROR)
            return false
        end
    end
    return true
end

-- put here the code to download the model if it is not found and auto_download opt is `true`
local function download_model(path, url, callback)
    if vim.fn.filereadable(path) == 1 then
        if callback then
            callback()
        end
        return
    end
    vim.notify("Downloading Kokoro model...", vim.log.levels.INFO)
    vim.fn.jobstart({ "curl", "-L", url, "-o", path }, {
        on_exit = function(_, code)
            if code == 0 then
                vim.notify("Model downloaded successfully", vim.log.levels.INFO)
                if callback then
                    callback()
                end
            else
                vim.notify("Failed to download model", vim.log.levels.ERROR)
            end
        end,
    })
end

-- here the code to download the voices when auto_download is `true`
local function download_voices(path, url, callback)
    if vim.fn.filereadable(path) == 1 then
        if callback then
            callback()
        end
        return
    end
    vim.notify("Downloading Kokoro voices...", vim.log.levels.INFO)
    vim.fn.jobstart({ "curl", "-L", url, "-o", path }, {
        on_exit = function(_, code)
            if code == 0 then
                vim.notify("Voices downloaded successfully", vim.log.levels.INFO)
                if callback then
                    callback()
                end
            else
                vim.notify("Failed to download voices", vim.log.levels.ERROR)
            end
        end,
    })
end

local server_job_id = nil

local function stop_server()
    if server_job_id then
        vim.fn.jobstop(server_job_id)
        server_job_id = nil
    end
end

local function start_server(opts)
    if server_job_id then
        return
    end

    local root = debug.getinfo(1).source:match("@?(.*)/"):gsub("/lua/sayit$", "")
    local server_path = root .. "/server.py"

    local log_path = vim.fn.stdpath("log") .. "/sayit_server.log"

    server_job_id = vim.fn.jobstart({ "uv", "run", server_path }, {
        cwd = root,
        env = {
            KOKORO_MODEL_PATH = opts.kokoro.model_path,
            KOKORO_VOICES_PATH = opts.kokoro.voices_path,
            INTRA_OP_THREADS = tostring(opts.kokoro.intra_op_threads),
            INTER_OP_THREADS = tostring(opts.kokoro.inter_op_threads),
        },
        on_stderr = function(_, data)
            if data and #data > 0 and data[1] ~= "" then
                local f = io.open(log_path, "a")
                if f then
                    f:write(table.concat(data, "\n") .. "\n")
                    f:close()
                end
            end
        end,
        on_exit = function()
            server_job_id = nil
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = stop_server,
    })
end

local default_opts = {
    server = {
        host = "localhost",
        port = 8000,
    },
    kokoro = {
        model_path = vim.fn.stdpath("data") .. "/kokoro-v1.0.onnx",
        voices_path = vim.fn.stdpath("data") .. "/voices-v1.0.bin",
        model_url = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
        voices_url = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
        auto_download = true,
        voice = "af_bella",
        speed = 1.0,
        lang = "en-us",
        intra_op_threads = 1,
        inter_op_threads = 1,
    },
    keymaps = {
        speak_selection = "<leader>ks",
        speak_buffer = "<leader>kb",
    },
}

local required_executables = { "curl", "mpv", "uv" }
local speak_job_id = nil

local function stop_speaking()
    if speak_job_id then
        local pid = vim.fn.jobpid(speak_job_id)
        if pid > 0 then
            -- On Linux/Unix, kill the process group or children
            -- This ensures that curl and mpv are also terminated
            vim.fn.system("pkill -P " .. pid)
        end
        vim.fn.jobstop(speak_job_id)
        speak_job_id = nil
    end
end

return {
    setup = function(opts)
        opts = opts or {}
        opts = vim.tbl_deep_extend("force", default_opts, opts)

        -- 1. check dependencies
        if not check_executables(required_executables) then
            return
        end

        -- 2. download model and voices if auto_download is true
        if opts.kokoro.auto_download then
            download_model(opts.kokoro.model_path, opts.kokoro.model_url, function()
                download_voices(opts.kokoro.voices_path, opts.kokoro.voices_url, function()
                    -- 3. start the server (only after downloads if auto_download is true)
                    start_server(opts)
                end)
            end)
        else
            -- 3. start the server immediately
            start_server(opts)
        end

        -- 4. setup the keymaps
        if opts.keymaps.speak_selection then
            vim.keymap.set("v", opts.keymaps.speak_selection, ":SayIt<CR>", { desc = "Speak selection" })
        end
        if opts.keymaps.speak_buffer then
            vim.keymap.set("n", opts.keymaps.speak_buffer, ":%SayIt<CR>", { desc = "Speak buffer" })
        end

        vim.api.nvim_create_user_command("ShutUp", stop_speaking, { desc = "Stop speaking" })

        vim.api.nvim_create_user_command("SayIt", function(args)
            stop_speaking()
            local lines = get_selection(args)
            local text = table.concat(lines, "\n")

            if not text or text == "" then
                vim.notify("No text to speak", vim.log.levels.WARN)
                return
            end

            local json_payload = vim.fn.json_encode({
                text = text,
                voice = opts.kokoro.voice,
                speed = opts.kokoro.speed,
                lang = opts.kokoro.lang,
            })

            local url = string.format("http://%s:%d/tts", opts.server.host, opts.server.port)
            -- We use a temporary file for the payload to avoid shell escape issues with large text
            local tmp_json = vim.fn.tempname() .. ".json"
            local f = io.open(tmp_json, "w")
            if f then
                f:write(json_payload)
                f:close()
            end

            local cmd = string.format(
                "curl -N -s -X POST %s -H 'Content-Type: application/json' -d @%s | mpv --no-terminal --profile=low-latency --cache=no -",
                url,
                tmp_json
            )

            vim.notify("Speaking...", vim.log.levels.INFO)

            speak_job_id = vim.fn.jobstart({ "sh", "-c", cmd }, {
                on_exit = function()
                    os.remove(tmp_json)
                    speak_job_id = nil
                end,
            })
        end, { range = true, desc = "Stream TTS to speak text" })
    end,
}
