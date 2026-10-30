local fh_util = require("fh_util")

local max_connectors = 256 -- shared across both wire colours and wildcard inputs
local max_depth = 32 -- wire edges and wildcard output-to-input transitions

local function add_signal(items, signal, quality)
    if signal and (not signal.type or signal.type == "item") then
        fh_util.add_item_to_table(items, signal, quality)
    end
end

local function is_wildcard(signal)
    return signal and signal.type == "virtual" and (
        signal.name == "signal-each" or signal.name == "signal-anything" or signal.name == "signal-everything"
    )
end

local function add_recipe_items(items, entries, quality)
    for _, entry in pairs(entries) do
        add_signal(items, entry, quality)
    end
end

local function collect_constant_signals(items, control)
    for _, section in pairs(control.sections) do
        for _, filter in pairs(section.filters) do
            add_signal(items, filter.value)
        end
    end
end

local function collect_crafting_signals(items, owner, control)
    if control.circuit_read_contents or control.circuit_read_ingredients then
        local recipe, quality = owner.get_recipe()

        if recipe then
            add_recipe_items(items, recipe.ingredients, quality)

            if control.circuit_read_contents then
                add_recipe_items(items, recipe.products, quality)
            end
        end
    end

    if control.circuit_read_working then
        add_signal(items, control.circuit_working_signal)
    end

    if control.circuit_read_recipe_finished then
        add_signal(items, control.circuit_recipe_finished_signal)
    end
end

---@param entity LuaEntity
---@param items table<string, ItemWithQuality>
---Find live item signals and configured item signals even when their current value is zero.
return function(entity, items)
    local ids = defines.wire_connector_id
    local pending, queued, networks = {}, {}, {}

    local function enqueue_connector(connector, depth)
        if not connector or not connector.valid or depth > max_depth or #pending >= max_connectors then
            return
        end

        local owner_id = connector.owner.unit_number or connector.owner
        local id = connector.wire_connector_id

        queued[owner_id] = queued[owner_id] or {}

        if queued[owner_id][id] then
            return
        end

        -- Deduplicate before queuing so cycles cannot consume the connector budget.
        queued[owner_id][id] = true
        pending[#pending + 1] = { connector = connector, depth = depth }
    end

    local function enqueue(owner, id, depth)
        enqueue_connector(owner.get_wire_connector(id, false), depth)
    end

    local function enqueue_inputs(owner, selection, depth)
        if not selection or selection.red then
            enqueue(owner, ids.combinator_input_red, depth)
        end

        if not selection or selection.green then
            enqueue(owner, ids.combinator_input_green, depth)
        end
    end

    local function collect_output(signal, owner, selection, depth)
        add_signal(items, signal)

        if is_wildcard(signal) then
            enqueue_inputs(owner, selection, depth + 1)
        end
    end

    local function collect_outputs(outputs, owner, depth)
        if not outputs then
            return
        end

        for _, output in pairs(outputs) do
            -- Networks select the count source only when copying counts.
            local input_networks = output.networks

            if output.copy_count_from_input == false then
                input_networks = nil
            end

            collect_output(output.signal, owner, input_networks, depth)
        end
    end

    local function collect_combinator_signals(owner, control, entity_type, id, depth)
        if id ~= ids.combinator_output_red and id ~= ids.combinator_output_green then
            return
        end

        local parameters = control.parameters

        if not parameters then
            return
        end

        if entity_type == "arithmetic-combinator" then
            collect_output(parameters.output_signal, owner, parameters.first_signal_networks, depth)
        else
            collect_outputs(parameters.outputs, owner, depth)
            collect_outputs(parameters.else_outputs, owner, depth)
        end
    end

    local function collect_configured_signals(connector, depth)
        local owner = connector.owner
        local id = connector.wire_connector_id
        local control = owner.get_control_behavior()

        if not control then
            return
        end

        -- Output selection affects configured signals, not physical wire traversal.
        local selection = control.output_networks

        if selection then
            local red = id == ids.circuit_red or id == ids.combinator_output_red
            local green = id == ids.circuit_green or id == ids.combinator_output_green
            if (red and not selection.red) or (green and not selection.green) then
                return
            end
        end

        local entity_type = fh_util.get_effective_type(owner)

        if entity_type == "constant-combinator" then
            collect_constant_signals(items, control)
        elseif entity_type == "arithmetic-combinator" or entity_type == "decider-combinator" then
            collect_combinator_signals(owner, control, entity_type, id, depth)
        elseif entity_type == "assembling-machine" or entity_type == "furnace" then
            collect_crafting_signals(items, owner, control)
        end
    end

    enqueue(entity, ids.circuit_red, 0)
    enqueue(entity, ids.circuit_green, 0)

    local index = 1

    while index <= #pending do
        local entry = pending[index]
        local connector, depth = entry.connector, entry.depth

        index = index + 1

        local owner = connector.owner
        local id = connector.wire_connector_id
        -- Read each reached network once, keeping red and green values separate.
        local network_id = connector.network_id

        if network_id ~= 0 and not networks[network_id] then
            networks[network_id] = true
            for _, signal in pairs(owner.get_signals(id) or {}) do
                add_signal(items, signal.signal)
            end
        end

        -- Follow wires only; an entity's other ports are separate circuit networks.
        for _, connection in pairs(connector.real_connections) do
            enqueue_connector(connection.target, depth + 1)
        end

        collect_configured_signals(connector, depth)
    end
end
