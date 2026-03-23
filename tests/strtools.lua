---@diagnostic disable: undefined-global, undefined-field
require("plenary.busted")

describe("loop.utils.strtools.split_shell_args", function()
  local split_shell_args = require("loop.utils.strtools").split_shell_args

  local function t(input, expected)
    it("splits '" .. input .. "' correctly", function()
      local result = split_shell_args(input)
      assert.are.same(expected, result)
    end)
  end

  -- Basic argument splitting
  t("hello world", { "hello", "world" })
  t("  hello   world  ", { "hello", "world" })
  t("cmd --flag -x", { "cmd", "--flag", "-x" })

  -- Quoted strings (preserve spaces)
  t([[echo "hello world"]], { "echo", "hello world" })
  t([["hello world" again]], { "hello world", "again" })
  t([['single "quotes" inside']], { 'single "quotes" inside' })

  -- Mixed quotes
  t([["double 'single' inside" 'and "double" here']], {
    "double 'single' inside",
    'and "double" here'
  })

  -- Escaped characters
  t([[echo \"quoted\"]], { "echo", "\"quoted\"" })
  t([[echo \\"backslash\\"]], { "echo", "\\backslash\\" })

  -- Escaped spaces (outside quotes)
  t([[echo hello\ world]], { "echo", "hello world" })
  t([[cmd a\ b c\ d]], { "cmd", "a b", "c d" })

  -- Escaped quotes inside quotes
  t([["He said \"hi\""]], { 'He said "hi"' })
  t([['It\'s a test']], { "It's a test" })

  -- Empty strings and edge cases
  t("", {})
  t("   ", {})
  t("word ", { "word" })
  t(" word", { "word" })

  -- Unterminated quotes (treated as literal text per spec)
  t([["unterminated]], { "\"unterminated" })
  t([['unfinished]], { "'unfinished" })

  -- Mixed quoted/unquoted parts → shell concatenates them
  t([[cmd "a"b"c"]], { "cmd", "abc" })

  -- Real-world CMake example
  t([[cmake -G "Ninja" -DCMAKE_BUILD_TYPE=Release -- -j4]], {
    "cmake",
    "-G",
    "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "--",
    "-j4"
  })

  -- Complex mixed case with backslash line continuations
  t([[
    run --config "Debug Mode" \
      --output='out dir' \
      "input file.txt"
  ]], {
    "run",
    "--config",
    "Debug Mode",
    "--output=out dir",
    "input file.txt"
  })
end)
