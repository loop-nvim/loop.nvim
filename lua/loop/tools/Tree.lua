local class = require("loop.tools.class")

---@class loop.tools.Tree.Item
---@field id any
---@field data any

---@class loop.tools.Tree.Node
---@field parent_id any|nil
---@field data any
---@field first_child any|nil
---@field last_child any|nil
---@field next_sibling any|nil
---@field prev_sibling any|nil

---@generic T
---@class loop.tools.Tree
---@field new fun(self: loop.tools.Tree) : loop.tools.Tree
---@field _nodes table<any, loop.tools.Tree.Node>
---@field _root_first any|nil
---@field _root_last any|nil
local Tree = class()

---Initialize internal state
function Tree:init()
	---@type table<any, loop.tools.Tree.Node>
	self._nodes = {}

	---@type any|nil
	self._root_first = nil

	---@type any|nil
	self._root_last = nil
end

--==============================================================
-- Internal Helpers
--===============================================================

---Link a node as the last child of a parent.
---@private
---@param parent_id any|nil
---@param id any
function Tree:_link_child(parent_id, id)
	local parent = parent_id and self._nodes[parent_id]
	if not parent then
		-- link under root list
		if not self._root_first then
			self._root_first = id
			self._root_last = id
		else
			local last = self._root_last
			self._nodes[last].next_sibling = id
			self._nodes[id].prev_sibling = last
			self._root_last = id
		end
		return
	end

	-- Normal case: parent exists
	if not parent.first_child then
		parent.first_child = id
		parent.last_child = id
	else
		local last = parent.last_child
		self._nodes[last].next_sibling = id
		self._nodes[id].prev_sibling = last
		parent.last_child = id
	end
end

---Link a node immediately before or after a reference sibling.
---@private
---@param id any
---@param reference_id any
---@param before boolean true to insert before, false to insert after
function Tree:_link_sibling(id, reference_id, before)
	local ref_node = self._nodes[reference_id]
	assert(ref_node, "reference_id does not exist")

	local parent_id = ref_node.parent_id

	local node = self._nodes[id]
	assert(node, "node must exist before linking")

	if before then
		-- Inserting before reference
		if parent_id == nil then
			-- Root level
			if reference_id == self._root_first then
				-- Inserting before first root node
				node.prev_sibling = nil
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				self._root_first = id
			else
				-- Inserting in the middle
				local prev_ref = ref_node.prev_sibling
				node.prev_sibling = prev_ref
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				if prev_ref then
					self._nodes[prev_ref].next_sibling = id
				end
			end
		else
			-- Child level
			local parent = self._nodes[parent_id]
			if reference_id == parent.first_child then
				-- Inserting before first child
				node.prev_sibling = nil
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				parent.first_child = id
			else
				-- Inserting in the middle
				local prev_ref = ref_node.prev_sibling
				node.prev_sibling = prev_ref
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				if prev_ref then
					self._nodes[prev_ref].next_sibling = id
				end
			end
		end
	else
		-- Inserting after reference
		if parent_id == nil then
			-- Root level
			if reference_id == self._root_last then
				-- Inserting after last root node
				node.prev_sibling = reference_id
				node.next_sibling = nil
				ref_node.next_sibling = id
				self._root_last = id
			else
				-- Inserting in the middle
				local next_ref = ref_node.next_sibling
				node.prev_sibling = reference_id
				node.next_sibling = next_ref
				ref_node.next_sibling = id
				if next_ref then
					self._nodes[next_ref].prev_sibling = id
				end
			end
		else
			-- Child level
			local parent = self._nodes[parent_id]
			if reference_id == parent.last_child then
				-- Inserting after last child
				node.prev_sibling = reference_id
				node.next_sibling = nil
				ref_node.next_sibling = id
				parent.last_child = id
			else
				-- Inserting in the middle
				local next_ref = ref_node.next_sibling
				node.prev_sibling = reference_id
				node.next_sibling = next_ref
				ref_node.next_sibling = id
				if next_ref then
					self._nodes[next_ref].prev_sibling = id
				end
			end
		end
	end
end

function Tree:_unlink(id)
	local node = self._nodes[id]
	if not node then return end

	local parent_id = node.parent_id
	local prev = node.prev_sibling
	local next = node.next_sibling

	-- 1. Fix parent's first/last child pointers
	if parent_id == nil then
		-- Root level
		if id == self._root_first then self._root_first = next end
		if id == self._root_last then self._root_last = prev end
	else
		local parent = self._nodes[parent_id]
		if parent then
			if id == parent.first_child then parent.first_child = next end
			if id == parent.last_child then parent.last_child = prev end
		end
	end
	-- 2. Fix sibling chain
	if prev then
		local prev_node = self._nodes[prev]
		if prev_node then
			prev_node.next_sibling = next
		end
	end
	if next then
		local next_node = self._nodes[next]
		if next_node then
			next_node.prev_sibling = prev
		end
	end
	-- 3. Clear this node's sibling pointers
	node.prev_sibling = nil
	node.next_sibling = nil
end

---Recursively remove a node and all of its descendants.
---@private
---@param id any
function Tree:_remove_subtree(id)
	local node = self._nodes[id]
	if not node then return end

	local child = node.first_child
	while child do
		local next_child = self._nodes[child].next_sibling
		self:_remove_subtree(child) -- recurse first
		child = next_child
	end

	self:_unlink(id)
	self._nodes[id] = nil
end

--==============================================================
-- Public API
--==============================================================

---Insert or update a node.
---
---If the node exists:
---  - update its data
---  - reparent if parent_id changed
---
---If new:
---  - create the node
---  - link it to parent
---

--- Replace the children of parent_id with exactly these items, in order.
---@generic T
---@param parent_id any|nil
---@param items loop.tools.Tree.Item[]
function Tree:set_children(parent_id, items)
	assert(type(items) == "table")
	local parent_node = parent_id and self._nodes[parent_id]
	assert(not parent_id or parent_node, "parent does not exist")

	-- 1. Remove ALL old children
	do
		local child
		if parent_node then
			child = parent_node.first_child
		else
			child = self._root_first
		end
		while child do
			local next_child = self._nodes[child].next_sibling
			self:_remove_subtree(child)
			child = next_child
		end

		if parent_node then
			parent_node.first_child = nil
			parent_node.last_child  = nil
		else
			self._root_first = nil
			self._root_last  = nil
		end
	end

	-- 2. Add new children
	local first_new = nil
	local last_new  = nil

	for _, item in ipairs(items) do
		local id = assert(item.id, "item must have .id")
		assert(self._nodes[id] == nil, ("duplicate id: %s"):format(tostring(id)))

		local node = {
			parent_id    = parent_id,
			data         = item.data,
			first_child  = nil,
			last_child   = nil,
			next_sibling = nil,
			prev_sibling = nil,
		}
		self._nodes[id] = node

		node.prev_sibling = last_new
		if last_new then
			self._nodes[last_new].next_sibling = id
		end
		if not first_new then first_new = id end
		last_new = id
	end

	-- 3. Link to parent (or root)
	if parent_node then
		parent_node.first_child = first_new
		parent_node.last_child  = last_new
	else
		self._root_first = first_new
		self._root_last  = last_new
	end
end

---Update the children of a parent node, merging with existing nodes.
---
---Existing children are updated in place if present.
---New children are added, and missing children are removed.
---@param parent_id any|nil
---@param items loop.tools.Tree.Item[]
---@param merge_data_fn fun(old:any,new:any):any
function Tree:update_children(parent_id, items, merge_data_fn)
	---@type loop.tools.Tree.Node[]
	local existing = {}
	for _, child in ipairs(self:get_children(parent_id)) do
		existing[child.id] = self._nodes[child.id]
	end

	local final_children = {}
	for _, incoming in ipairs(items) do
		local node = existing[incoming.id]
		if node then
			-- Merge data
			if merge_data_fn then
				node.data = merge_data_fn(node.data, incoming.data)
			else
				node.data = incoming.data
			end
			-- Remove all existing children of this reused node
			local child = node.first_child
			while child do
				local next_child = self._nodes[child].next_sibling
				self:_remove_subtree(child)
				child = next_child
			end
			node.first_child = nil
			node.last_child  = nil
			table.insert(final_children, node)
			existing[incoming.id] = nil
		else
			-- New node
			node = {
				id           = incoming.id,
				parent_id    = parent_id,
				data         = incoming.data,
				first_child  = nil,
				last_child   = nil,
				prev_sibling = nil,
				next_sibling = nil,
			}
			self._nodes[incoming.id] = node
			table.insert(final_children, node)
		end
	end

	-- Remove orphans
	for _, orphan in pairs(existing) do
		self:_remove_subtree(orphan.id)
	end

	-- Rebuild the linked list for parent
	local prev_id = nil
	local first_new = nil
	local last_new = nil
	for _, node in ipairs(final_children) do
		local id = node.id
		node.prev_sibling = prev_id
		node.next_sibling = nil
		if prev_id then
			self._nodes[prev_id].next_sibling = id
		end
		if not first_new then first_new = id end
		prev_id = id
		last_new = id
	end

	if parent_id then
		local parent_node       = self._nodes[parent_id]
		parent_node.first_child = first_new
		parent_node.last_child  = last_new
	else
		self._root_first = first_new
		self._root_last  = last_new
	end
end

---@generic T
---@param parent_id any|nil
---@param id any
---@param data T
function Tree:upsert_item(parent_id, id, data)
	assert(id ~= nil, "id is required")
	assert(parent_id == nil or self._nodes[parent_id], "parent does not exist")

	local node = self._nodes[id]
	if node then
		-- Update data
		node.data = data

		-- Reparent if needed
		if node.parent_id ~= parent_id then
			-- CYCLE DETECTION:
			-- If we are moving A under C, ensure C is not already a child of A.
			if parent_id ~= nil and self:_is_ancestor(id, parent_id) then
				error("cycle detected: cannot move a node under its own descendant")
			end

			-- 1. Unlink from old parent (does not delete children)
			self:_unlink(id)

			-- 2. Update parent reference
			node.parent_id = parent_id

			-- 3. Relink under new parent
			self:_link_child(parent_id, id)
		end
	else
		-- Create new node
		node = {
			parent_id    = parent_id,
			data         = data,
			first_child  = nil,
			last_child   = nil,
			next_sibling = nil,
			prev_sibling = nil,
		}
		self._nodes[id] = node

		-- Link under parent or root
		self:_link_child(parent_id, id)
	end
end

---Insert or update a node before or after a reference sibling.
---
---If the node exists:
---  - update its data
---  - reparent if parent_id changed
---  - move to position before or after sibling_id
---
---If new:
---  - create the node
---  - link it to parent before or after sibling_id
---
---@generic T
---@param id any
---@param data T
---@param sibling_id any
---@param before boolean true to insert before sibling, false to insert after
function Tree:insert_sibling(id, data, sibling_id, before)
	assert(id ~= nil, "id is required")
	assert(sibling_id ~= nil, "sibling_id is required")

	local ref_node = self._nodes[sibling_id]
	assert(ref_node, "sibling_id does not exist")

	local parent_id = ref_node.parent_id

	local node = self._nodes[id]
	if node then
		-- Update data
		node.data = data

		-- Reparent if needed
		if node.parent_id ~= parent_id then
			-- CYCLE DETECTION:
			-- If we are moving A under C, ensure C is not already a child of A.
			if parent_id ~= nil and self:_is_ancestor(id, parent_id) then
				error("cycle detected: cannot move a node under its own descendant")
			end

			-- 1. Unlink from old parent (does not delete children)
			self:_unlink(id)

			-- 2. Update parent reference
			node.parent_id = parent_id

			-- 3. Relink under new parent at correct position
			self:_link_sibling(id, sibling_id, before)
		else
			-- Same parent, but may need to reposition
			-- Only reposition if not already in the correct position
			local needs_reposition = false
			if before then
				needs_reposition = node.next_sibling ~= sibling_id
			else
				needs_reposition = node.prev_sibling ~= sibling_id
			end

			if needs_reposition then
				-- Unlink from current position
				self:_unlink(id)
				-- Relink at correct position
				self:_link_sibling(id, sibling_id, before)
			end
		end
	else
		-- Create new node
		node = {
			parent_id    = parent_id,
			data         = data,
			first_child  = nil,
			last_child   = nil,
			next_sibling = nil,
			prev_sibling = nil,
		}
		self._nodes[id] = node

		-- Link under parent or root at correct position
		self:_link_sibling(id, sibling_id, before)
	end
end

---@param parent_id any
---@param items loop.tools.Tree.Item[]
function Tree:upsert_items(parent_id, items)
	assert(type(items) == "table", "items must be a table")
	assert(parent_id == nil or self._nodes[parent_id], "parent does not exist")

	for _, item in ipairs(items) do
		local id   = assert(item.id, "each item must have an 'id'")
		local data = item.data

		local node = self._nodes[id]
		if node then
			-- Update data
			node.data = data

			-- Reparent if needed
			if node.parent_id ~= parent_id then
				-- CYCLE DETECTION:
				-- If we are moving A under C, ensure C is not already a child of A.
				if parent_id ~= nil and self:_is_ancestor(id, parent_id) then
					error("cycle detected: cannot move a node under its own descendant")
				end

				-- Remove from old parent (keeps subtree intact)
				self:_unlink(id)

				-- Update parent reference
				node.parent_id = parent_id

				-- Link under new parent
				self:_link_child(parent_id, id)
			end
		else
			-- Create new node
			node = {
				parent_id    = parent_id,
				data         = data,
				first_child  = nil,
				last_child   = nil,
				next_sibling = nil,
				prev_sibling = nil,
			}
			self._nodes[id] = node

			-- Link into child chain
			self:_link_child(parent_id, id)
		end
	end
end

--- Is this node a root node? (has no parent)
---@return boolean
function Tree:is_root(id)
	local node = self._nodes[id]
	return node and node.parent_id == nil
end

--- Get root nodes (same as get_children(nil) but maybe clearer name in some contexts)
function Tree:get_roots()
	return self:get_children(nil)
end

--- Get the parent ID of a node (or nil if it's a root node)
---@param id any
---@return any|nil parent_id
function Tree:get_parent_id(id)
	assert(id ~= nil, "id is required")
	local node = self._nodes[id]
	if not node then
		return nil -- or error("node does not exist") — your choice
	end
	return node.parent_id
end

---@param id any
---@return any -- node data or nil
function Tree:get_item(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.data or nil
end

---@return loop.tools.Tree.Item[]
function Tree:get_items()
	local items = {}
	for id, node in pairs(self._nodes) do
		table.insert(items, { id = id, data = node.data })
	end
	return items
end

---@param id any
---@return boolean
function Tree:have_children(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.first_child ~= nil
end

---Get all immediate children of a node in order.
---@param parent_id any|nil If nil, returns root nodes.
---@return loop.tools.Tree.Item[]
function Tree:get_children(parent_id)
	local items = {}
	local child_id

	if parent_id == nil then
		child_id = self._root_first
	else
		local node = self._nodes[parent_id]
		if not node then return items end
		child_id = node.first_child
	end

	while child_id do
		local node = self._nodes[child_id]
		table.insert(items, { id = child_id, data = node.data })
		child_id = node.next_sibling
	end

	return items
end

---Remove a node and all its descendants.
---@param id any
function Tree:remove_item(id)
	assert(id, "id required")
	self:_remove_subtree(id)
end

---Remove all children of a node but keep the node itself.
---@param id any
function Tree:remove_children(id)
	assert(id ~= nil, "id is required")
	local node = self._nodes[id]

	-- If node doesn't exist, there's nothing to clear
	if not node then return end

	local child = node.first_child
	while child do
		-- Grab the next sibling before removing the current child subtree
		local next_child = self._nodes[child].next_sibling
		self:_remove_subtree(child)
		child = next_child
	end

	-- Clear the pointers on the parent so it no longer thinks it has children
	node.first_child = nil
	node.last_child = nil
end

--==============================================================
-- Flattening (for UI)
--==============================================================

---A flattened node structure (for UI rendering).
---@class loop.tools.Tree.FlatNode
---@field id any
---@field data any
---@field depth integer

---Flatten the tree in depth-first order.
---
---Used for UIs (Neovim buffers, virtual lists, etc.)
---@param filter (fun(id:any,data:any):nil|"keep"|"exclude"|"exclude_children")|nil
---@return loop.tools.Tree.FlatNode[]
function Tree:flatten(filter)
	---@type loop.tools.Tree.FlatNode<any>[]
	local out = {}

	-- Set to track visited node IDs during this traversal
	local visited = {}
	local path = {} -- for better error reporting (shows the cycle path)

	local function walk(id, depth, filter_applied)
		local node = self._nodes[id]
		if not node then
			error(string.format("Tree:flatten() - Invalid node id %s (nil node)", tostring(id)))
		end

		local filter_mode
		if not filter_applied then
			filter_mode = filter and filter(id, node.data) or nil
			if filter_mode then
				filter_applied = true
				if filter_mode == 'exclude' then
					goto continue
				end
			end
		end

		-- Cycle detection
		if visited[id] then
			-- Build a readable cycle path
			local cycle_start = id
			local path_str = {}
			for i = #path, 1, -1 do
				table.insert(path_str, 1, tostring(path[i]))
				if path[i] == cycle_start then break end
			end
			table.insert(path_str, tostring(id)) -- close the loop

			assert(false, string.format(
				"Cycle detected in tree structure during flatten(): %s → %s (loop closes)",
				table.concat(path_str, " → "), tostring(id)
			))
		end

		-- Mark as being visited (in current path)
		visited[id] = true
		table.insert(path, id)

		out[#out + 1] = {
			id = id,
			data = node.data,
			depth = depth,
		}

		if not filter_mode or filter_mode ~= 'exclude_children' then
			local child = node.first_child
			while child do
				walk(child, depth + 1, filter_applied)
				child = self._nodes[child].next_sibling
			end
		end

		-- Backtrack: remove from current path
		table.remove(path)

		::continue::
	end

	local id = self._root_first
	while id do
		-- Reset visited set for each root (in case of forest with shared _nodes - which shouldn't happen in a tree)
		-- But to be safe and allow detection across roots if somehow shared
		if visited[id] then
			assert(false, string.format("Node %s appears under multiple roots - not a valid forest", tostring(id)))
		end
		walk(id, 0, false)
		id = self._nodes[id].next_sibling
	end

	return out
end

---Check if potential_ancestor_id is a descendant of id (to prevent cycles)
---@private
function Tree:_is_ancestor(id, potential_ancestor_id)
	local current_id = potential_ancestor_id
	while current_id do
		if current_id == id then return true end
		local node = self._nodes[current_id]
		current_id = node and node.parent_id
	end
	return false
end

return Tree
