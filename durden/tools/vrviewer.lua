--
-- Simple VR window manager and image- /model- viewer
--
-- this is written so that it can be wrapped around a small stub loader
-- so that it can be broken out into a separate arcan appl of its own,
-- not needing to piggyback on durden.
--
-- see the use of vrmenus and vrsetup.lua
--

local hmd_arg = "";
local setup_vr = system_load("tools/vrviewer/vrsetup.lua")();

--
-- local function get_valid_windows(cwin, model)
-- 	local lst = {};
-- 	for wnd in all_windows() do
-- 		if (wnd ~= cwin) then
--			local ident = wnd.title_text and wnd.title_text or wnd.name;
--			table.insert(lst, {
--				kind = "action",
--				name = "map_" .. wnd.name,
--				label = "w:" .. ident,
--				eval = function() return valid_vid(cwin.model); end,
--				handler = function()
--					image_sharestorage(wnd.canvas, cwin.model);
--					cwin:set_title(string.format("VR/Panoramic: %s", ident));
--				end
--			});
--		end
--	end
--	return lst;
-- end

local function drag_rotate(ctx, vid, dx, dy)
	rotate3d_model(ctx.wnd.camera, 0, dy, dx, 0, ROTATE_RELATIVE);
end

local function model_rotate(ctx, vid, dx, dy)
	local layer = ctx.wnd.selected_layer;
	if (not layer or not layer.selected) then
		return;
	end
	local v = layer.selected;
	v.rel_ang[2] = v.rel_ang[2] + dy;
	v.rel_ang[3] = v.rel_ang[3] + dx;
	rotate3d_model(v.vid,
		v.rel_ang[1], v.rel_ang[2], v.rel_ang[3] + v.layer_ang);
end

local function drag_layer(ctx, vid, dx, dy)
	local layer = ctx.wnd.selected_layer;
	if (not layer or layer.fixed) then
		return;
	end

	layer:step(dx, dy);
end

local function drag_scale(ctx, vid, dx, dy)
	local layer = ctx.wnd.selected_layer;
	if (not layer or not layer.selected) then
		return;
	end
	local model = layer.selected;

-- disable animation temporarily
	local as = model.ctx.animation_speed;
	model.ctx.animation_speed = 0;

-- work with a 'scale factor' which retains aspect ratio even when on the sides
	local tot = 0.01 * (dx + dy);
	model:set_scale_factor(tot, true);
	model.layer:relayout();

	model.ctx.animation_speed = as;
end

local function vrwnd()
	local preview = alloc_surface(320, 320);
	image_texfilter(preview, FILTER_BILINEAR);

-- and bind to a new window
	local wnd = active_display():add_window(preview, {scalemode = "stretch"});

	if (not wnd) then
		delete_image(preview);
		return;
	end

-- no default symbol bindings
	wnd.clipboard_block = true;
	wnd:set_title(string.format("VR/Panoramic - unmapped"));

-- this will append functions for adding layers and models
	setup_vr(wnd, preview, {
		prefix = "tools/vrviewer",
		curve = 0.9
	});

-- leases that we have taken from the display manager
	wnd.leases = {};

-- make sure that we return the VR displays to the display manager
	wnd:add_handler("destroy",
	function()
		for _,v in ipairs(wnd.leases) do
			map_video_display(BADID, v.id);
			display_release(v.name);
		end
	end);

-- if the window gets dragged, resize the context to match
	wnd:add_handler("resize", function(ctx, w, h)
		if (not ctx.in_drag_rz) then
			image_resize_storage(preview, w, h);
			rendertarget_forceupdate(preview);
		end
		resize_image(preview, w, h);
	end);

-- switch mouse handler so canvas drag translates to rotating the camera
	wnd.handlers.mouse.canvas.drag = drag_rotate;
	wnd.handlers.mouse.canvas.wnd = wnd;

	local lst = {};
	for k,v in pairs(wnd.handlers.mouse.canvas) do
		table.insert(lst, k);
	end
	wnd.handlers.mouse.canvas.wnd = wnd;
	mouse_droplistener(wnd.handlers.mouse.canvas);
	mouse_addlistener(wnd.handlers.mouse.canvas, lst);

	wnd.receive_cursortag =
	function(wnd, probe, srcwnd)
		if (not wnd.default_model and not wnd.default_cp) then
			return false;
		end

-- First [decode] + external_model? prefer that. Only open ended question
-- is if this should prompt the mapping taking over if the parent window
-- is terminated. A popup to query is probably the right way.
		if (srcwnd.atype == "decode" and wnd.default_model) then
			if (not probe) then
				wnd.default_model.external = wnd.external;
				image_sharestorage(srcwnd.canvas, wnd.default_model.vid);
				wnd.default_model:show();
			end
			return true;
		end

-- Otherwise we first try direct migration
		if (wnd.default_cp) then
			if (not valid_vid(srcwnd.external, TYPE_FRAMESERVER)) then
				return false;
			end

			if (not probe) then
				target_devicehint(srcwnd.external, wnd.default_cp, true);
			end
			return true;
		end

-- And fallback to mapping
		if (not probe) then
			wnd.default_model.external = wnd.external;
			image_sharestorage(srcwnd.canvas, wnd.default_model.vid);
			wnd.default_model:show();
		end

		return true;
	end

	show_image(preview);
	wnd.menu_state_disable = true;

-- add window specific menus that expose the real controls
	opts = {
		prefix = "tools/vrviewer/"
	};

	wnd.actions = (system_load("tools/vrviewer/vrmenus.lua")())(wnd, opts);

	table.insert(wnd.actions,
{
	name = "mouse",
	kind = "value",
	description = "Change the current mouse cursor behavior when dragged or locked",
	label = "Mouse",
	set = {"Selected", "View", "Layer Distance", "Model Scale", "Model Rotate"},
	handler = function(ctx, val)
		if (val == "View") then
			wnd.handlers.mouse.canvas.drag = drag_rotate;
			wnd.handlers.mouse.canvas.motion = function() end;

		elseif (val == "Layer Distance") then
			wnd.handlers.mouse.canvas.drag = drag_layer;
			wnd.handlers.mouse.canvas.motion = function() end;

		elseif (val == "Model Scale") then
			wnd.handlers.mouse.canvas.drag = drag_scale;
			wnd.handlers.mouse.canvas.motion = function() end;

		elseif (val == "Model Rotate") then
			wnd.handlers.mouse.canvas.drag = model_rotate;
			wnd.handlers.mouse.canvas.motion = function() end;
		else
			wnd.handlers.mouse.canvas.drag = function() end;
			wnd.handlers.mouse.canvas.motion = function(ctx, vid, dx, dy, x, y)
-- missing, forward mouse input to client
			end;
		end
	end
});

	table.insert(wnd.actions,
	{
	name = "vrsetup",
	label = "Activate",
	kind = "value",
	description = "Activate the VR pipe on a simulated window or real HMD",
	set =
	function()
		local res = {"simulated"};
		display_bytag("VR", function(disp)
			table.insert(res, disp.name);
		end);
		return res;
	end,
	handler = function(ctx, val)
		if (val == "simulated") then
			wnd.active_vr = wnd:setup_vr(
				function(ctx, vid)
					local wnd = active_display():add_window(
						vid, "VR Simulated Output", {scalemode = "stretch"});
				end, {headless = true}
			);
		else
			local disp = display_lease(val);
			if (not disp) then
				active_display():message("couldn't lease " .. val);
				return;
			end
			table.insert(wnd.leases, disp);

			wnd.active_vr = wnd:setup_vr(
				function(ctx, vid)
					if (BADID == vid) then
						active_display():message("vr bridge terminated");
						map_video_display(BADID, v.id);
						table.remove_match(wnd.leases, disp);
						display_release(disp.name);
						return;
					end
					link_image(vid, wnd.anchor);
					map_video_display(vid, disp.id, HINT_PRIMARY);
				end, {}
			);
		end
	end,
	eval = function()
		return not wnd.active_vr;
	end
	}
	);

	return wnd;
end

menus_register("global", "tools",
{
	name = "vr",
	label = "VR Viewer",
	description = "Panoramic/VR Viewer",
	kind = "action",
-- engine version check
	eval = function()
		return build_cylinder ~= nil;
	end,
	handler = vrwnd
});
