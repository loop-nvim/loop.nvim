---@diagnostic disable: undefined-global, undefined-field
require("plenary.busted")
local Tree = require("loop.tools.Tree")

describe("loop.tools.Tree (new API)", function()

    ------------------------------------------------------------
    -- Basic insertion
    ------------------------------------------------------------

    it("inserts a root item", function()
        local tree = Tree:new()

        tree:add_item(nil, "A", { value = 1 })
        tree:validate()

        assert.equal("A", tree._root_first)
        assert.equal("A", tree._root_last)
        assert.same(nil, tree:get_parent_id("A"))

        local flat = tree:flatten()
        assert.same({
            { id = "A", data = { value = 1 }, depth = 0 }
        }, flat)
    end)

    it("inserts children in order", function()
        local tree = Tree:new()

        tree:add_item(nil, "A", {})
        tree:add_item("A", "B", {})
        tree:add_item("A", "C", {})
        tree:add_item("A", "D", {})
        tree:validate()

        local A = tree._nodes["A"]

        assert.equal("B", A.first_child)
        assert.equal("D", A.last_child)
        assert.equal("C", tree._nodes["B"].next_sibling)
        assert.equal("D", tree._nodes["C"].next_sibling)
        assert.is_nil(tree._nodes["D"].next_sibling)
    end)

    ------------------------------------------------------------
    -- Data updates
    ------------------------------------------------------------

    it("updates item data without changing position", function()
        local tree = Tree:new()

        tree:add_item(nil, "A", { old = true })
        tree:set_item_data("A", { new = true })
        tree:validate()

        assert.same({ new = true }, tree:get_data("A"))
        assert.equal("A", tree._root_first)
    end)

    ------------------------------------------------------------
    -- Removal
    ------------------------------------------------------------

    it("removes a leaf node", function()
        local tree = Tree:new()

        tree:add_item(nil, "A", {})
        tree:add_item(nil, "B", {})
        tree:remove_item("B")
        tree:validate()

        assert.is_nil(tree._nodes["B"])

        local flat = tree:flatten()
        assert.same({
            { id = "A", data = {}, depth = 0 }
        }, flat)
    end)

    it("removes a subtree", function()
        local tree = Tree:new()

        tree:add_item(nil, "A", {})
        tree:add_item("A", "B", {})
        tree:add_item("B", "C", {})
        tree:remove_item("B")
        tree:validate()

        assert.is_nil(tree._nodes["B"])
        assert.is_nil(tree._nodes["C"])
    end)

    ------------------------------------------------------------
    -- set_children behavior (destructive replace)
    ------------------------------------------------------------

    it("replaces children using set_children", function()
        local tree = Tree:new()

        tree:add_item(nil, "Parent", {})

        tree:set_children("Parent", {
            { id = "A", data = {} },
            { id = "B", data = {} },
        })

        tree:validate()

        assert.equal("A", tree._nodes["Parent"].first_child)
        assert.equal("B", tree._nodes["Parent"].last_child)
    end)

    it("set_children destroys old subtree", function()
        local tree = Tree:new()

        tree:add_item(nil, "P", {})
        tree:add_item("P", "Old", {})
        tree:add_item("Old", "Deep", {})

        tree:set_children("P", {
            { id = "New", data = {} }
        })

        tree:validate()

        assert.is_nil(tree._nodes["Old"])
        assert.is_nil(tree._nodes["Deep"])
        assert.truthy(tree._nodes["New"])
    end)

    it("set_children works on root", function()
        local tree = Tree:new()

        tree:set_children(nil, {
            { id = "R1", data = {} },
            { id = "R2", data = {} },
        })

        tree:validate()

        assert.equal("R1", tree._root_first)
        assert.equal("R2", tree._root_last)
    end)

    it("set_children with empty list clears children", function()
        local tree = Tree:new()

        tree:add_item(nil, "P", {})
        tree:add_item("P", "A", {})
        tree:add_item("P", "B", {})

        tree:set_children("P", {})
        tree:validate()

        assert.is_nil(tree._nodes["A"])
        assert.is_nil(tree._nodes["B"])
        assert.is_nil(tree._nodes["P"].first_child)
    end)

    ------------------------------------------------------------
    -- add_sibling
    ------------------------------------------------------------

    it("inserts sibling before reference", function()
        local tree = Tree:new()

        tree:set_children(nil, {
            { id = "A", data = {} },
            { id = "C", data = {} },
        })

        tree:add_sibling("C","B", {},  true)
        tree:validate()

        local flat = tree:flatten()
        assert.same({
            { id = "A", depth = 0, data = {} },
            { id = "B", depth = 0, data = {} },
            { id = "C", depth = 0, data = {} },
        }, flat)
    end)

    it("inserts sibling after reference", function()
        local tree = Tree:new()

        tree:set_children(nil, {
            { id = "A", data = {} },
            { id = "B", data = {} },
        })

        tree:add_sibling("B", "C", {}, false)
        tree:validate()

        assert.equal("C", tree._root_last)
    end)

    ------------------------------------------------------------
    -- flatten behavior
    ------------------------------------------------------------

    it("handles flatten on empty tree", function()
        local tree = Tree:new()
        assert.same({}, tree:flatten())
    end)

    it("flattens deep nesting correctly", function()
        local tree = Tree:new()

        tree:add_item(nil, "R", {})
        tree:add_item("R", "A", {})
        tree:add_item("A", "B", {})
        tree:add_item("B", "C", {})
        tree:validate()

        local flat = tree:flatten()

        assert.same({
            { id = "R", depth = 0, data = {} },
            { id = "A", depth = 1, data = {} },
            { id = "B", depth = 2, data = {} },
            { id = "C", depth = 3, data = {} },
        }, flat)
    end)

    it("respects exclude_children filter", function()
        local tree = Tree:new()

        tree:add_item(nil, "A", {})
        tree:add_item("A", "B", {})
        tree:add_item("B", "C", {})

        local flat = tree:flatten(nil, function(id)
            if id == "B" then
                return false
            end
        end)

        assert.same({
            { id = "A", depth = 0, data = {} },
            { id = "B", depth = 1, data = {} },
        }, flat)
    end)

end)