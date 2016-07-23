--
-- a pulldown terminal that lives outside the normal window manager
-- downside is that input handling and other features behave differently
--
--
-- MISSING:
-- display migration (with fonts)
-- mouse injection
-- cut/paste
-- terminal font config synch
-- config- menu injection
-- default keybinding setting(?)
--

local dstate = {
	dir_x = 0,
	dir_y = 1,
	pos = "top",
	ofs = 0,
	width = 0.5,
	height = 0.3
};

gconfig_register("dt_width", 0.5);
gconfig_register("dt_height", 0.4);
gconfig_register("dt_opa", 0.8);

local function update_size()
	if (valid_vid(dstate.term, TYPE_FRAMESERVER)) then
		local disp = active_display();
		local neww = disp.width * gconfig_get("dt_width");
		local newh = disp.height * gconfig_get("dt_height");
		target_displayhint(dstate.term, neww, newh);
	end
end

local dterm_cfg = {
{
	label = "Width",
	name = "width",
	kind = "value",
	hint = "(100 * val)%",
	validator = gen_valid_float(0.1, 1.0),
	initial = function() return gconfig_get("dt_width"); end,
	handler = function(ctx, val)
		gconfig_set("dt_weight", tonumber(val));
		update_size();
	end
},
{
	label = "Height",
	name = "height",
	kind = "value",
	hint = "(100 * val)%",
	validator = gen_valid_float(0.1, 1.0),
	initial = function() return gconfig_get("dt_width"); end,
	handler = function(ctx, val)
		gconfig_set("dt_height", tonumber(val));
		update_size();
	end
},
{
	label = "Background Alpha",
	name = "alpha",
	kind = "value",
	hint = "(0..1, 1=opaque)",
	validator = gen_valid_float(0.0, 1.0),
	initial = function() return gconfig_get("dt_opa"); end,
	handler = function(ctx, val)
		gconfig_set("dt_opa", tonumber(val));
		if (valid_vid(dstate.term, TYPE_FRAMESERVER)) then
			target_graphmode(dstate.term, gconfig_get("dt_opa"));
		end
	end
}
};

local atype = extevh_archetype("terminal");

local function drop()
	reset_image_transform(dstate.term); -- use RV to adjust animation time?
	local props = image_surface_properties(dstate.term);
	nudge_image(dstate.term,
		-1 * dstate.dir_x * props.width, -1 * dstate.dir_y * props.height,
		gconfig_get("animation")
	);
	blend_image(dstate.term, 0.0, gconfig_get("animation"));
	dstate.active = false;
	dispatch_toggle(false);
	mouse_lockto(unpack(dstate.lock));

	target_displayhint(dstate.term, 0, 0,
		bit.bor(TD_HINT_UNFOCUSED, TD_HINT_INVISIBLE));
end

-- we intercept symbol- handling so our trigger path can be re-used
-- but forward the rest to the new window
local function ldisp(sym, iotbl, path)
	if (not sym and not iotbl) then
		drop();
		return;
	end

-- label translation
	if (iotbl.label and atype.labels[iotbl.label]) then
		iotbl.label = atype.labels[iotbl.label];
	end

-- don't consume mouse here as we want to translate to the specific surface
	if (iotbl.mouse) then
		return false, sym, iotbl, path;
	end

	target_input(dstate.term, iotbl);

-- run through the terminal archetype label binding
	return true, sym, iotbl, path;
end

-- different rules apply to input and event response compared to normal windows
local function termh(source, status)
	if (status.kind == "resized") then
		resize_image(source, status.width, status.height);
	elseif (status.kind == "terminated") then
		if (dstate.active) then
			drop();
		end
		delete_image(source);
		dstate.term = nil;
	end
end

local function dterm()
-- if we're already toggled, then disable
	if (dstate.active) then
		drop();
		return;
	end

-- if we got a terminal running, prefer that
-- or spawn a new one.. create anchor, attach, order, ...
	local disp = active_display();
	local neww = disp.width * gconfig_get("dt_width");
	local newh = disp.height * gconfig_get("dt_height");

	if (not valid_vid(dstate.term)) then
		dstate.term = spawn_terminal(string.format("width=%d:height=%d", neww, newh), true);
		dstate.disp = disp;
		target_updatehandler(dstate.term, termh);
		target_graphmode(dstate.term, gconfig_get("dt_opa"));
	end

-- reattach to different output on switch or resize
	if (dstate.disp ~= active_display()) then
		target_displayhint(dstate.term, neww, newh);
		dstate.disp = active_display();
-- send font hint
-- reevaluate width, resize
	end

-- put us in the "special" overlay order range
	order_image(dstate.term, 65532);

-- center at hidden state non-dominant axis, account for user- padding
-- do this the safe "all options rather than math" way due to the possible
-- switching of user- config between spawns
	if (dstate.dir_x ~= 0) then
		neww = neww + dstate.ofs;
		if (dstate.dir_x > 0) then
			move_image(dstate.term, -neww, 0.5 * (disp.height - newh));
			nudge_image(dstate.term, neww, 0, gconfig_get("animation"));
		else
			move_image(dstate.term, disp.width, 0.5 * (disp.height - newh));
			nudge_image(dstate.term, -neww, 0, gconfig_get("animation"));
		end
	elseif (dstate.dir_y ~= 0) then
		newh = newh + dstate.ofs;
		if (dstate.dir_y > 0) then -- top
			move_image(dstate.term, 0.5 * (disp.width - neww), -newh);
			nudge_image(dstate.term, 0, newh, gconfig_get("animation"));
		else -- bottom
			move_image(dstate.term, 0.5 * (disp.width - neww), disp.height);
			nudge_image(dstate.term, 0, -newh, gconfig_get("animation"));
		end
	end

	blend_image(dstate.term, 1.0, gconfig_get("animation"));
	dstate.active = true;
	dispatch_toggle(ldisp);

	local v, f, w, s = mouse_lockto(dstate.term,
		function(rx, ry, x, y, state, ind, active)
			local props = image_surface_properties(dstate.term);
			x = x - props.x;
			y = y - props.y;
		end, nil
	);
	dstate.lock = {v, f, w, s};
	target_displayhint(dstate.term, 0, 0, 0);
end

global_menu_register("tools",
{
	name = "dterm",
	label = "Drop-down Terminal",
	kind = "action",
	handler = dterm
});

global_menu_register("settings/tools",
{
	name = "dterm",
	label = "Drop-down Terminal",
	kind = "action",
	submenu = true,
	handler = dterm_cfg
});