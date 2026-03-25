---@diagnostic disable: undefined-global, undefined-field
require("plenary.busted")
local LRU = require("loop.utils.LRU")

-- Internal helper to get keys in order for assertions
local function get_keys(cache)
    local keys = {}
    for k in cache:iter_items() do
        table.insert(keys, k)
    end
    return keys
end

describe("loop.utils.LRU", function()
    it("should initialize with correct capacity and empty state", function()
        local cache = LRU:new(3)
        assert.are.equal(3, cache._capacity)
        assert.are.equal(0, cache:size())
        assert.is_nil(cache._head)
        assert.is_nil(cache._tail)
    end)

    it("should store and retrieve values", function()
        local cache = LRU:new(2)
        cache:put("a", 100)
        assert.are.equal(100, cache:get("a"))
        assert.are.equal(1, cache:size())
    end)

    it("should move accessed items to the front (MRU)", function()
        local cache = LRU:new(3)
        cache:put("a", 1)
        cache:put("b", 2)
        cache:put("c", 3)

        -- Current order: c, b, a
        cache:get("a") -- 'a' moves to front

        assert.are.same({ "a", "c", "b" }, get_keys(cache))
    end)

    it("should evict the _tail when capacity is exceeded", function()
        local cache = LRU:new(2)
        cache:put("a", 1)
        cache:put("b", 2)
        cache:put("c", 3) -- 'a' (the _tail) should be evicted

        assert.is_false(cache:has("a"))
        assert.is_true(cache:has("b"))
        assert.is_true(cache:has("c"))
        assert.are.equal(2, cache:size())
    end)

    it("should update existing keys without increasing size", function()
        local cache = LRU:new(5)
        cache:put("key", 1)
        cache:put("key", 2)

        assert.are.equal(2, cache:get("key"))
        assert.are.equal(1, cache:size())
    end)

    it("should delete specific keys and fix pointers", function()
        local cache = LRU:new(3)
        cache:put("a", 1)
        cache:put("b", 2)
        cache:put("c", 3)

        cache:delete("b") -- Delete middle node

        assert.are.equal(2, cache:size())
        assert.are.same({ "c", "a" }, get_keys(cache))
        assert.are.equal(cache._head.next, cache._tail)
    end)

    it("should peek without affecting order", function()
        local cache = LRU:new(2)
        cache:put("a", 1)
        cache:put("b", 2)

        -- Peek 'a' (the _tail)
        assert.are.equal(1, cache:peek("a"))

        -- Order should still be b, a
        assert.are.same({ "b", "a" }, get_keys(cache))

        -- Adding 'c' should still evict 'a'
        cache:put("c", 3)
        assert.is_false(cache:has("a"))
    end)

    it("should handle clearing the cache and calling on_removed", function()
        local removed_keys = {}
        local cache = LRU:new(2, {
            on_removed = function(k) table.insert(removed_keys, k) end
        })
        cache:put("a", 1)
        cache:put("b", 2)
        cache:clear()

        assert.are.equal(0, cache:size())
        assert.is_nil(cache._head)
        assert.is_nil(cache._tail)
        -- clear() iterates MRU -> LRU
        assert.are.same({ "b", "a" }, removed_keys)
    end)

    describe("Callbacks (on_evict vs on_removed)", function()
        it("should trigger both on eviction", function()
            local evict_k, remove_k
            local cache = LRU:new(1, {
                on_evict = function(k) evict_k = k end,
                on_removed = function(k) remove_k = k end
            })

            cache:put("a", 1)
            cache:put("b", 2) -- Evicts "a"

            assert.are.equal("a", evict_k)
            assert.are.equal("a", remove_k)
        end)

        it("should trigger only on_removed on manual delete", function()
            local evict_called = false
            local removed_key
            local cache = LRU:new(5, {
                on_evict = function() evict_called = true end,
                on_removed = function(k) removed_key = k end
            })

            cache:put("target", 123)
            cache:delete("target")

            assert.is_false(evict_called)
            assert.are.equal("target", removed_key)
        end)

        it("should trigger only on_removed on clear", function()
            local evict_count = 0
            local removed_count = 0
            local cache = LRU:new(2, {
                on_evict = function() evict_count = evict_count + 1 end,
                on_removed = function() removed_count = removed_count + 1 end
            })

            cache:put("a", 1)
            cache:put("b", 2)
            cache:clear()

            assert.are.equal(0, evict_count)
            assert.are.equal(2, removed_count)
        end)
    end)

    it("should handle boundary logic for 1-capacity cache", function()
        local cache = LRU:new(1)

        -- Add first item
        cache:put("a", 1)
        assert.are.equal(cache._head, cache._tail)
        assert.are.equal(1, cache:get("a"))

        -- Add second item (should evict "a")
        cache:put("b", 2)

        -- Fix: Check for the value 2, not the string 'b'
        assert.are.equal(2, cache:get("b"))
        assert.is_false(cache:has("a"))

        -- Verify pointers in 1-node list
        assert.are.equal(cache._head, cache._tail)
        assert.is_nil(cache._head.next)
        assert.is_nil(cache._head.prev)
    end)
end)

it("should promote an item to the front without changing value", function()
    local cache = LRU:new(3)
    cache:put("a", 1)
    cache:put("b", 2)
    cache:put("c", 3)

    -- Order: c, b, a
    cache:promote("a")

    -- Order should now be: a, c, b
    assert.are.same({ "a", "c", "b" }, get_keys(cache))
    assert.are.equal(1, cache:peek("a"))

    -- Promoting an already-front item should do nothing
    cache:promote("a")
    assert.are.same({ "a", "c", "b" }, get_keys(cache))

    -- Promoting a non-existent key should not error
    assert.has_no.errors(function() cache:promote("non-existent") end)
end)

it("should maintain valid _head/_tail pointers through complex sequences", function()
    local cache = LRU:new(2)

    cache:put("a", 1) -- [a]
    cache:put("b", 2) -- [b, a]
    cache:get("a")    -- [a, b]
    cache:delete("a") -- [b]

    assert.are.equal(cache._head, cache._tail)
    assert.are.equal("b", cache._head.key)

    cache:put("c", 3) -- [c, b]
    cache:delete("b") -- [c]

    assert.are.equal(cache._head, cache._tail)
    assert.is_nil(cache._head.next)
    assert.is_nil(cache._head.prev)

    cache:delete("c") -- []
    assert.is_nil(cache._head)
    assert.is_nil(cache._tail)
    assert.are.equal(0, cache:size())
end)
