-- Copyright: 2015-2018, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://durden.arcan-fe.com
--
-- Description: The display- set of functions tracks connected displays
-- and respond to plug/unplug events. They are also responsible for the
-- creation of tiler- window managers and manual or automatic migration
-- between window managers and their corresponding display.
--

-- default PPCM, particularly some capture devices that tamper with EDID.
if VPPCM > 240 then
	VPPCM = 32
end

local SIZE_UNIT = 38.4;
local displays = {};
local profiles = {};
local ignored = {};
local display_listeners = {};

-- there's no other way to detect the presence of LWA mode at the moment
-- (which is just stupid since some functions have different semantics)
local arcan_nested = VRES_AUTORES ~= nil;

local wm_alloc_function = function() end

local display_debug = suppl_add_logfn("display");

local function disp_string(disp)
	return string.format("id=%d:name=%s:maphint=%d:w=%d:h=%d:backlight=%d:ppcm=%f",
		disp.id and disp.id or -1, disp.name and disp.name or "broken",
		disp.maphint and disp.maphint or -1,
		disp.w and disp.w or -1,
		disp.h and disp.h or -1,
		disp.backlight and disp.backlight or -1,
		disp.ppcm and disp.ppcm or -1
	);
end

-- always return a valid string, for debug log tagging
local function get_disp_name(name)
	if (type(name) == "string") then
		return name;
	elseif (type(name) == "number") then
		return tostring(number);
	else
		return "invalid";
	end
end

local function get_disp(name)
	local found, foundi;
	for k,v in ipairs(displays) do
		if (type(name) == "string" and v.name == name) then
			found = v;
			foundi = k;
			break;
		elseif (type(name) == "number" and v.id == name) then
			found = v;
			foundi = k;
		end
	end
	return found, foundi;
end

local function tryload(v)
	local res = system_load(v, 0);

	if (not res) then
		warning("parsing error loading display map: " .. v);
		return;
	end

	local okstate, map = pcall(res);
	if (not okstate or type(map) ~= "table") then
		warning("execution error loading map: " .. v);
		return;
	end

	if (type(map.name) ~= "string" or
		type(map.ident) ~= "string") then
		warning("bad obligatory fields in map: " .. v);
		return;
	end

	local rv = {
		name = map.name,
		ident = map.ident,
		tag = map.tag
	};

-- copy and sanity check optional fields

	if (type(map.ppcm) == "number" and map.ppcm < 200 and map.ppcm > 10) then
		rv.ppcm = map.ppcm;
	end

	if (type(map.wm) == "string") then
		if (map.wm == "tiler" or map.wm == "ignore") then
			rv.wm = map.wm;
		end
	end

	if (type(map.backlight) == "number" and map.backlight > 0.0) then
		rv.backlight = map.backlight;
	end

	if (type(map.width) == "number" and map.width > 0) then
		rv.width = map.width;
	end

	if (type(map.height) == "number" and map.height > 0) then
		rv.height = map.height;
	end

	return rv;
end

function display_scanprofiles()
	profiles = {};
	local lst = glob_resource("devmaps/display/*.lua", APPL_RESOURCE);
	if (not lst) then
		return;
	end
	table.sort(lst);
	for k,v in ipairs(lst) do
		local res = tryload("devmaps/display/" .. v);
		if (res) then
			table.insert(profiles, res);
		end
	end
end

display_scanprofiles();

function display_maphint(disp)
	if (type(disp) == "string") then
		disp = get_disp(disp);
	end

	if (type(disp) ~= "table") then
		return HINT_NONE;
	end

	return bit.bor(disp.maphint, (disp.primary and HINT_PRIMARY or 0));
end

local function autohome_spaces(ndisp)
	local migrated = false;

	for i, disp in ipairs(displays) do
		local tiler = disp.tiler;
		if (tiler and tiler ~= ndisp.tiler) then
			for i=1,10 do
				if (tiler.spaces[i] and tiler.spaces[i].home and
					tiler.spaces[i].home == ndisp.name) then
					tiler.spaces[i]:migrate(ndisp.tiler);
					migrated = true;
					display_debug(
						string.format("autohome:%s:%d:%s", tiler.name, i, ndisp.name));
				end
			end
		end
	end
end

local function set_mouse_scalef()
	local sf = gconfig_get("mouse_scalef");
	mouse_cursor_sf(sf * displays[displays.main].tiler.scalef,
		sf * displays[displays.main].tiler.scalef);
end

-- execute [cb] in the attachment context of [tiler], needed with
-- rendertargets as images created has a default attachment unless
-- one is explicitly set
function display_tiler_action(tiler, cb)
	for i,v in ipairs(displays) do
		if (v.tiler == tiler) then
			local save = displays.main;
			set_context_attachment(v.rt);
			cb();
			set_context_attachment(displays[save].rt);
			return;
		end
	end
end

-- same as for display_tiler_action, just a different lookup function
function display_action(disp, cb)
	local save = displays.main;

	if (type(disp) == "number") then
		set_context_attachment(disp);
	else
		set_context_attachment(disp.rt);
	end
	cb();
	set_context_attachment(displays[save].rt);
end

local function switch_active_display(ind)
	if (displays[ind] == nil or not valid_vid(displays[ind].rt)) then
		return;
	end

	displays[displays.main].tiler:deactivate();
	displays[ind].tiler:activate();
	displays.main = ind;
	set_context_attachment(displays[ind].rt);
	mouse_querytarget(displays[ind].rt);
	display_debug(string.format("active_display:%d", ind));
	set_mouse_scalef();
end

local function set_best_mode(disp, desw, desh)
-- fixme, enumerate list of modes and pick one that has a fitting
-- resolution and refresh
	local list = video_displaymodes(disp.id);
	if (not list or #list == 0) then
		display_debug("mode_error:message=no_mode:display=" .. tostring(disp.id));
		return;
	end

	if (not desw or not desh) then
		desw = disp.w;
		desh = disp.h;
	end

-- just score based on match against w/h
	table.sort(list, function(a, b)
		local dx = desw - a.width;
		local dy = desh - a.height;
		local ea = math.sqrt((dx * dx) + (dy * dy));
		local dx = desw - b.width;
		local dy = desh - b.height;
		local eb = math.sqrt((dx * dx) + (dy * dy));

-- same resolution? take the matching refresh, not the highest as that would
-- excluding have a device- profile override
		if (ea == eb) then
			return math.abs(disp.refresh - a.refresh) < math.abs(disp.refresh - b.refresh);
		end

		return ea < eb;
	end);

	display_debug(
		string.format("mode_set:display=%d:width=%d:height=%d:refresh=%d",
		disp.id, list[1].width, list[1].height, list[1].refresh)
	);

	video_displaymodes(disp.id, list[1].modeid);
end

local function get_ppcm(pw_cm, ph_cm, dw, dh)
	return (math.sqrt(dw * dw + dh * dh) /
		math.sqrt(pw_cm * pw_cm + ph_cm * ph_cm));
end

function display_count()
	return #displays;
end

-- "hard" fullscreen- mode where the window canvas is mapped directly to
-- the display without going through the detour of a rendertarget. Note that
-- this is not as close as we can go yet, but requires more platform support
-- and loses the ability to apply a shader.
--
-- The 'real' version would require not only a mode-switch but:
--
--  * track producer state and mark that we need a scanout capable buffer
--    (which depend on the buffer format and so on) handle and wrap- shmif
--    vbuf-only drawing into such a buffer. This can already
--
--  * for kms-, have arcan directly wrap the shmif- part into a DMAbuf and
--    send that as the scanout for cases.
--
--  * use more native post-processing for ICC-/ gamma correction
--
function display_fullscreen(name, vid, modesw, mapv)
	local disp = get_disp(name);
	if (not disp) then
		return;
	end

-- invalid vid == switch back, do so by reactivating rendertarget
-- updates and possible switch back to the last known mode
	if not valid_vid(vid) then
		display_debug("fullscreen:off");

		for i, j in ipairs(displays) do
			if (valid_vid(j.rt)) then
				rendertarget_forceupdate(j.rt, -1);
			end
		end

		map_video_display(disp.rt, disp.id, display_maphint(disp));
		if (disp.last_m and disp.fs_modesw) then
			video_displaymodes(disp.id, disp.last_m.modeid);
		end

		disp.monitor_vid = nil;
		disp.monitor_sprops = nil;

		if (disp.fs_mode) then
			local ws = disp.tiler.spaces[disp.tiler.space_ind];
			if (type(ws[disp.fs_mode]) == "function") then
				ws[disp.fs_mode](ws);
			end
			disp.fs_mode = nil;
		end

-- otherwise enter fullscreen, switch each rendertarget to a configurable
-- 'in background' refresh rate to permit other effects etc. to be running
-- but at a lower rate than the focused vid
	else
		display_debug(string.format("fullscreen:%d", disp.id));
		for i,j in ipairs(displays) do
			if (valid_vid(j.rt)) then
				rendertarget_forceupdate(j.rt, gconfig_get("display_fs_rtrate"));
			end
		end

		disp.monitor_vid = vid;
		local ws = disp.tiler.spaces[disp.tiler.space_ind];
		disp.fs_mode = ws.mode;
		map_video_display(vid, disp.id, display_maphint(disp));
	end

-- will be applied in tick as we don't know what render state we are called from
	disp.fs_modesw = modesw;
end

local function find_profile(name)
	for k,v in ipairs(profiles) do
		if (string.match(name, v.ident)) then
			return v;
		end
	end
end

-- parse and decode display information from the edid block, possible that
-- we should allow an edid override here as well - though linux etc. provide
-- that at a lower level
local function display_data(id)
	local data, hash = video_displaydescr(id);
	local model = "unknown";
	local serial = "unknown";
	if (not data) then
		return;
	end

-- data should typically be EDID, if it is 128 bytes long we assume it is
	if (string.len(data) == 128 or string.len(data) == 256) then
		for i,ofs in ipairs({54, 72, 90, 108}) do

			if (string.byte(data, ofs+1) == 0x00 and
			string.byte(data, ofs+2) == 0x00 and
			string.byte(data, ofs+3) == 0x00) then
				if (string.byte(data, ofs+4) == 0xff) then
					serial = string.sub(data, ofs+5, ofs+5+12);
				elseif (string.byte(data, ofs+4) == 0xfc) then
					model = string.sub(data, ofs+5, ofs+5+12);
				end
			end

		end
	end

	local strip = function(s)
		local outs = {};
		local len = string.len(s);
		for i=1,len do
			local ch = string.sub(s, i, i);
			if string.match(ch, '[a-zA-Z0-9]') then
				table.insert(outs, ch);
			end
		end
		return table.concat(outs, "");
	end

	return strip(model), strip(serial);
end

local function get_name(id)
	local name;
	if (id == 0) then
		name = "default_";
	else
-- first mapping nonsense has previously made it easier (?!)
-- getting a valid EDID in some cases, might need to move this
-- workaround to the platform layer though
		name = "unknown_" .. tostring(id);
		map_video_display(displays[1].rt, id, HINT_NONE);
	end
	local model, serial = display_data(id);
	if (model) then
		name = string.split(model, '\r')[1] .. "/" .. serial;
	else
		display_debug(string.format("id=%d:error=", id, "no_edid"));
	end
	return name;
end

local function display_byname(name, id, w, h, ppcm)
	local res = {
		w = w,
		h = h,
		rw = w,
		rh = h,
		ppcm = ppcm,
		id = id,
		name = get_name(id),
		shader = gconfig_get("display_shader"),
		maphint = HINT_NONE,
		refresh = 60,
		backlight = 1.0,
		wm = "tiler"
	};

	local pref = "disp_" .. string.hexenc(res.name) .. "_";
	local keys = match_keys(pref .. "%");

	for i,v in ipairs(keys) do
		local ind = string.find(v, "=");
		if (ind) then
			local key = string.sub(string.sub(v, 1, ind-1), string.len(pref) + 1);
			local val = string.sub(v, ind+1);
			if (key == "ppcm") then
				if (tonumber(val)) then
					res.ppcm = tonumber(val);
				end
			elseif (key == "map") then
				if (tonumber(val)) then
					res.maphint = tonumber(val);
				end
			elseif (key == "shader") then
				res.shader = val;
			elseif (key == "bg") then
				res.bg = val;
			elseif (key == "primary") then
				res.primary = tonumber(val) == 1;
			elseif (key == "w") then
				res.w = tonumber(val);
			elseif (key == "h") then
				res.h = tonumber(val);
			elseif (key == "refresh") then
				res.refresh = tonumber(val);
			elseif (key == "backlight") then
				res.backlight = tonumber(val);
			else
				warning("unknown stored display setting with key " .. key);
			end
		end
	end

-- profile takes precedence over cached database key
	local prof = find_profile(name);
	if (prof) then
		if (prof.width) then
			res.w = prof.width;
		end
		if (prof.height) then
			res.h = prof.height;
		end
		if (prof.refresh) then
			res.refresh = prof.refresh;
		end
		if (prof.ppcm) then
			res.ppcm = prof.ppcm;
			res.ppcm_override = prof.ppcm;
		end
		if (prof.backlight) then
			res.backlight = math.clamp(prof.backlight, 0.1, 1.0);
		end
		res.tag = prof.tag;
		res.wm = prof.wm;
	end

-- distinguish between real-width and effective-width (rotation)
	res.rw = res.w;
	res.rh = res.h;
	return res;
end

-- assume that we somehow lost state and have a valid display, rebuild it
-- with the contents of the provided table
local function display_apply(display)
	display_override_density(display.name, display.ppcm);
	display_reorient(display.name, display.maphint);
	display_shader(display.name, display.shader);

	if (display.bg and display.tiler) then
		display.tiler:set_background(bg);
	end
end

function display_manager_shutdown()
	local ktbl = {};

	for i,v in ipairs(displays) do
		print("display", v.name, v.shader)
		local pref = "disp_" .. string.hexenc(v.name) .. "_";

		if (v.ppcm_override) then
			ktbl[pref .. "ppcm"] = v.ppcm;
		end
		if (v.maphint) then
			ktbl[pref .. "map"] = v.maphint;
		end
		if (v.shader) then
			ktbl[pref .. "shader"] = v.shader;
-- MISSING: pack/unpack shader arguments
		end
		if (v.backlight) then
			ktbl[pref .. "backlight"] = v.backlight;
		end
		ktbl[pref .. "bg"] = v.background and v.background or "";

		if (v.rw) then
			ktbl[pref .. "w"] = v.rw;
		end
		if (v.rh) then
			ktbl[pref .. "h"] = v.rh;
		end
		if (v.refresh) then
			ktbl[pref .. "refresh"] = v.refresh;
		end
		ktbl[pref .. "primary"] = v.primary and 1 or 0;
	end
	store_key(ktbl);
end

local function reorient_ddisp(disp, hint)
-- is an explicit map hint set? then toggle the bits but preserve
-- other ones like CROP or FILL or PRIMARY
	local mfl = bit.bor(HINT_ROTATE_CW_90, HINT_ROTATE_CCW_90);
	if (hint ~= nil) then
		local valid = bit.bor(HINT_ROTATE_CW_90, HINT_ROTATE_CCW_90);
		valid = bit.bor(valid, HINT_YFLIP);
		hint = bit.band(valid, hint);
		local mask = bit.band(disp.maphint, bit.bnot(valid));
		disp.maphint = bit.bor(mask, hint);

-- otherwise invert the current one
	else
		if (bit.band(disp.maphint, mfl) > 0) then
			disp.maphint = bit.band(disp.maphint, bit.bnot(mfl));
		else
			disp.maphint = bit.bor(disp.maphint, HINT_ROTATE_CW_90);
		end
	end

	local neww = disp.rw;
	local newh = disp.rh;
	if (bit.band(disp.maphint, mfl) > 0) then
		neww = disp.rh;
		newh = disp.rw;
	end

-- if the dimensions have changed, we should tell the tilers to reorg.
	if (neww ~= disp.w or newh ~= disp.h) then
		disp.w = neww;
		disp.h = newh;
		display_action(disp, function()
			disp.tiler:resize(neww, newh);
			disp.tiler:update_scalef(disp.tiler.scalef);
		end);

-- and this might have rebuilt the rendertarget as a new one, so switch
-- the query target that the mouse will check for picking on
		if (active_display(true) == disp.rt) then
			mouse_querytarget(disp.rt);
		end
	end

	map_video_display(disp.rt, disp.id, display_maphint(disp));
end

function display_set_backlight(name, ctrl, ind)
	local disp = get_disp(name);
	if (not disp) then
		return;
	end

	if not (ctrl and ctrl >= 0 and ind and ind >= 0) then
		disp.ledctrl = nil;
		disp.ledid = nil;
		return;
	end

	disp.ledctrl = ctrl;
	disp.ledid = ind;
	led_intensity(ctrl, ind, 255.0 * disp.backlight);
end

local function display_added(id)
	local modes = video_displaymodes(id);

-- "safe" defaults
	local dw = VRESW;
	local dh = VRESH;
	local ppcm = VPPCM;
	local subpx = "RGB";

-- map resolved display modes, assume [1] is the preferred one
	if (modes and #modes > 0 and modes[1].width > 0) then
		dw = modes[1].width;
		dh = modes[1].height;
		local wmm = modes[1].phy_width_mm;
		local hmm = modes[1].phy_height_mm;

		subpx = modes[1].subpixel_layout;
		subpx = subpx == "unknown" and "RGB" or subpx;

		if (wmm > 0 and hmm > 0) then
			ppcm = get_ppcm(0.1*wmm, 0.1*hmm, dw, dh);
		end
	end

	local ddisp;
	ddisp = display_add(get_name(id), dw, dh, ppcm, id);
	if (not ddisp) then
		return;
	end

	ddisp.id = id;

-- load possible overrides since before, note that this is slightly
-- inefficient as it will force rebuild of underlying rendertargets
-- etc. but it beats have to cover a number of corner cases / races
	ddisp.ppcm = ppcm;
	ddisp.subpx = subpx;

-- get the current state of the color ramps and attach to the disp-
-- table, for both internal and external 'gamma' correction.
	if (not ddisp.ramps) then
		ddisp.ramps = video_displaygamma(ddisp.id);
		ddisp.active_ramps = ddisp.ramps;
	end

	display_debug(disp_string(ddisp));
	display_apply(ddisp);
	map_video_display(ddisp.rt, id, display_maphint(ddisp));
	if (ddisp.bg) then
		ddisp.tiler:set_background(ddisp.bg);
	end
	for k,v in ipairs(display_listeners) do
		v("added", name, ddisp.tiler, id);
	end
end

local last_rescan = CLOCK;
function display_event_handler(action, id)
	if (displays.simple) then
		return;
	end

	display_debug(
		string.format("id=%d:event=%s", id and id or -1, action and action or ""));

-- display subsystem and input subsystem are connected when it comes
-- to platform specific actions e.g. virtual terminal switching, assume
-- keystate change between display resets.
	if (action == "reset") then
		dispatch_meta_reset();
		iostatem_reset_flag();
		return;
	end

	if (action == "added") then
		display_added(id);

-- remove on a previous display is more like tagging it as orphan
-- as it may reappear later
	elseif (action == "removed") then
		local ddisp = display_remove(name, id);
		if (ddisp) then
			for k,v in ipairs(display_listeners) do
				v("removed", name, ddisp.tiler, id);
			end
		end

	elseif (action == "changed") then
		active_display():message("rescanning GPUs on hotlug");
		video_displaymodes();
	end
end

--
-- a facility to monitor when a display is added or lost as some
-- global effects need to know about this in order to build fbos etc.
--
function display_add_listener(fcon)
	table.insert(display_listeners, fcon);
	for i,v in ipairs(displays) do
		fcon("added", v.name, v.tiler, v.id);
	end
end

function display_all_mode(mode)
	for i,v in ipairs(displays) do
		video_display_state(v.id, mode);
	end
end

function display_manager_init(alloc_fn)
	wm_alloc_function = alloc_fn;

-- Since we won't get an 'added / removed' event for this display, the defaults
-- and possible profile override needs to be activated manually. This should
-- really be reworked to have the same path for everything, the problem lies
-- with how the platform is setup in Arcan, which in turn ties back to openGL
-- setup without a working display.
	local name = get_name(0);
	local ddisp = display_byname(name, 0, VRESW, VRESH, VPPCM);

-- this might come from a preset profile, so sweep the available display maps
-- and pick the one with the best fit
	set_best_mode(ddisp);

-- virtual-display to-fix: there is an issue here when the system starts
-- without any connected display or when the first display happens to be
-- a VR display that should be ignored. What should be done is to create
-- a virtual-display and bind a tiler to that, then allow a display to
-- grab the orphaned virtual one.
	ddisp.tiler = wm_alloc_function(ddisp);
	displays[1] = ddisp;

	displays.simple = gconfig_get("display_simple");
	displays.main = 1;
	ddisp.tiler.name = "default";

-- simple mode does not permit us to do much of the fun stuff, like
-- different color etc. correction shaders or rotate/fit/.. it's
-- essentially just for low powered nested use

	if (not displays.simple) then
		rendertarget_forceupdate(WORLDID, 0);
		if (not arcan_nested) then
			delete_image(WORLDID);
		end
		ddisp.rt = ddisp.tiler:set_rendertarget(true);
		map_video_display(ddisp.rt, 0, 0);
		shader_setup(ddisp.rt, "display", ddisp.shader, ddisp.name);
		switch_active_display(1);
		reorient_ddisp(ddisp, ddisp.maphint);
		mouse_querytarget(ddisp.rt);
	end

	return ddisp.tiler;
end

function display_attachment()
	if (displays.simple) then
		return nil;
	else
		return displays[1].rt;
	end
end

function display_override_density(name, ppcm)
	local disp, dispi = get_disp(name);
	if (not disp) then
		return;
	end

-- it might be that the selected display is not currently the main one
	display_action(disp, function()
		disp.ppcm = ppcm;
		disp.ppcm_override = ppcm;
		disp.tiler:update_scalef(ppcm / SIZE_UNIT, {ppcm = ppcm});
		set_mouse_scalef();
	end);
end

-- override the default shader setting to packval, that can be expanded
-- upon display identification and shader setup
function display_shader_uniform(name, uniform, packval)
--	print("update uniform persistance", name, uniform, packval);
end

function display_shader(name, key)
	local disp, dispi = get_disp(name);
	if (not disp or not valid_vid(disp.rt)) then
		return;
	end

-- special path, the engine can optimize if we use the "DEFAULT" shader
	if (key == "basic") then
		image_shader(disp.rt, 'DEFAULT');
		disp.shader = key;
	elseif (key) then
		warning("shader" .. key);
		shader_setup(disp.rt, "display", key, disp.name);
		--set_key("disp_" .. hexenc(disp.name) .. "_shader", key);
		disp.shader = key;
	end
	map_video_display(disp.rt, disp.id, disp.maphint);

	return disp.shader;
end

function display_add(name, width, height, ppcm, id)
	local found = get_disp(name);
	local new = nil;
	local maphint = HINT_NONE;
	local backlight = 1.0;

	name = string.gsub(name, ":", "/");

	width = math.clamp(width, width, MAX_SURFACEW);
	height = math.clamp(height, height, MAX_SURFACEH);

-- for each workspace, check if they are homed to the display
-- being added, and, if space exists, migrate
	if (found) then
		display_debug(string.format("add_match:name=%s", string.hexenc(name)));
		found.orphan = false;
		image_resize_storage(found.rt, found.w, found.h);
		display_apply(found);

	else
		nd = display_byname(name, id, width, height, ppcm);
		if (nd.wm == "ignore") then
			table.insert(ignored, nd);
			return;
		end

-- make sure all resources are created in the global scope
		set_context_attachment(WORLDID);
		nd.tiler = wm_alloc_function(nd);
		table.insert(displays, nd);
		nd.ind = #displays;
		new = nd.tiler;

-- this will rebuild tiler with all its little things attached to rt
-- we hide it as we explicitly map to a display and do not want it
-- visible in the WORLDID domain, eating fillrate.
		nd.rt = nd.tiler:set_rendertarget(true);
		hide_image(nd.rt);

-- in the real case, we'd switch to the last known resolution
-- and then set the display to match the rendertarget
		found = nd;
		set_context_attachment(displays[displays.main].rt);
	end

-- this also takes care of spaces that are saved as preferring a certain disp.
	autohome_spaces(found);

	if (found.last_m) then
		display_ressw(name, found.last_m);
	end
	return found, new;
end

-- linear search all spaces in all displays except disp and
-- return the first empty one that is found
local function find_free_display(disp)
	for i,v in ipairs(displays) do
		if (not v.orphan and v ~= disp) then
			for j=1,10 do
				if (v.tiler:empty_space(j)) then
					return v;
				end
			end
		end
	end
end

-- sweep all used workspaces of the display and find new parents
local function autoadopt_display(disp)
	for i=1,10 do
		if (not disp.tiler:empty_space(i)) then
			local ddisp = find_free_display(disp);

-- chances are all displays are lost
			if (not ddisp) then
				return;
			end

			local space = disp.tiler.spaces[i];
			if (not space) then
				ddisp.tiler:switch_ws(i);
				space = ddisp.tiler.spaces[i];
			end

-- couldn't find a space to home into, keep pending and wait
			if (space) then
				space:migrate(ddisp.tiler);
				space.home = disp.name;
			end
		end
	end
end

-- allow external tools to register ignored devices by tag
function display_bytag(tag, yield)
	for _,v in ipairs(ignored) do
		if (v.tag == tag and not v.leased) then
			yield(v);
		end
	end
end

function display_lease(name)
	display_debug("lease:name=" .. get_disp_name(name));

	for k,v in ipairs(ignored) do
		if (v.name == name) then
			if (not v.leased) then
				display_debug("leased:name=" .. get_disp_name(name));
				v.leased = true;
				return v;
			else
				display_debug("lease_error:name=" .. get_disp_name(name));
			end
		end
	end

end

function display_release(name)
	display_debug("release:name=" .. get_disp_name(name));

	for k,v in ipairs(ignored) do
		if (v.name == name) then
			if (v.leased) then
				display_debug("released:name=" .. get_disp_name(name));
				v.leased = false;
				return;
			else
				display_debug("release_error:name=" .. get_disp_name(name));
			end
		end
	end
end

function display_remove(name, id)
	local found, foundi = get_disp(name);

-- first by name, then by id
	if (not found) then
		for k,v in ipairs(displays) do
			if (id and v.id == id) then
				found = v;
				foundi = k;
				break;
			end
		end

-- there is still the chance that some other tool manually managed the
-- display, this is used in the case of a VR modelviewer, for instance.
		if (not found) then
			for i,v in ipairs(ignored) do
				if v.id == id then
					if (v.handler) then
						v:handler("remove");
					end
					table.remove(ignored,i);
					return;

				end
			end
			display_debug("remove:error:unknown=" .. get_disp_name(name));
			return;
		end
	end

-- mark as orphan and reduce memory footprint by resizing the rendertarget
	display_debug("orphan:name=" .. get_disp_name(name));
	found.orphan = true;
	image_resize_storage(found.rt, 32, 32);
	hide_image(found.rt);

-- try and have another display adopt
	if (gconfig_get("ws_autoadopt") and autoadopt_display(found)) then
		found.orphan = false;
	end

-- if it was the main display we lost, cycle to the next one so that gets
-- set as main
	if (foundi == displays.main) then
		display_cycle_active(ws);
	end

	return found;
end

-- special little hook in LWA mode that handles resize requests from
-- parent. We treat that as a 'normal' resolution switch.
function VRES_AUTORES(w, h, vppcm, flags, source)
	local disp = displays[1];
	display_debug(string.format(
		"autores:id=0:w=%d:h=%d:ppcm=%f:flags=%d:source=%d",
		w, h, vppcm, flags, source)
	);

	for k,v in ipairs(displays) do
		if (v.id == source) then
			disp = v;
			break;
		end
	end

	if (gconfig_get("lwa_autores")) then
		if (displays.simple) then
			resize_video_canvas(w, h);
			disp.tiler:resize(w, h, true);
		else
			display_action(disp, function()
				if (video_displaymodes(source, w, h)) then
					map_video_display(disp.rt, 0, disp.maphint);
					resize_video_canvas(w, h);
					image_set_txcos_default(disp.rt);
					disp.tiler:resize(w, h);
					disp.tiler:update_scalef(disp.ppcm / SIZE_UNIT, {ppcm = disp.ppcm});
				end
			end);
		end
	end

end

function display_ressw(name, mode)
	local disp = get_disp(name);
	if (not disp) then
		warning("display_ressww(), invalid display reference for "
			.. tostring(name));
		return;
	end

-- track this so we can recover if the display is lost, readded and homed to def
	disp.last_m = mode;

	if (not disp.ppcm_override) then
		disp.ppcm = get_ppcm(0.1 * mode.phy_width_mm,
			0.1 * mode.phy_height_mm, mode.width, mode.height);
	end

	display_action(disp, function()
		disp.w = mode.width;
		disp.h = mode.height;
		disp.rw = disp.w;
		disp.rh = disp.h;
		video_displaymodes(disp.id, mode.modeid);
		if (valid_vid(disp.rt)) then
			image_set_txcos_default(disp.rt);
			map_video_display(disp.rt, disp.id, display_maphint(disp));
		end
		disp.tiler:resize(mode.width, mode.height) --, true);
		disp.tiler:update_scalef(disp.ppcm / SIZE_UNIT, {ppcm = disp.ppcm});
		set_mouse_scalef();
	end);

	if (disp.maphint) then
		display_reorient(name, disp.maphint);
	end

-- as the dimensions have changed
	if (active_display(true) == disp.rt) then
		mouse_querytarget(disp.rt);
	end
end

function display_cycle_active(ind)
	if (type(ind) == "boolean") then
		switch_active_display(displays.main);
		return;
	elseif (type(ind) == "number") then
		switch_active_display(ind);
		return;
	end

	local nd = displays.main;
	repeat
		nd = (nd + 1 > #displays) and 1 or (nd + 1);
	until (nd == displays.main or not
		(displays[nd].orphan or displays[nd].disabled));

	switch_active_display(nd);
end

function display_migrate_wnd(wnd, dstname)
	local dsp2 = get_disp(dstname);
	if (not dsp2) then
		return;
	end

	wnd:migrate(dsp2.tiler, {ppcm = dsp2.ppcm,
		width = dsp2.tiler.width, height = dsp2.tiler.height});
end

-- migrate the ownership of a single workspace to another display
function display_migrate_ws(tiler, dstname)
	local dsp2 = get_disp(dstname);
	if (not dsp2) then
		return;
	end

	if (#tiler.spaces[tiler.space_ind].children > 0) then
		tiler.spaces[tiler.space_ind]:migrate(dsp2.tiler,
			{ppcm = dsp2.ppcm,
			width = dsp2.tiler.width, height = dsp2.tiler.height
		});
		tiler:tile_update();
		dsp2.tiler:tile_update();
	end
end

function display_reorient(name, hint)
	if (displays.simple) then
		return;
	end

	local disp = get_disp(name);
	if (not disp) then
		warning("display_reorient on missing display:" .. tostring(name));
		return;
	end

	reorient_ddisp(disp, hint);
end

function display_simple()
	return displays.simple;
end

function display_share(disp, args, recfn)
	if (not valid_vid(disp.rt)) then
		return;
	end

	if (disp.share_slot) then
		delete_image(disp.share_slot);
		disp.share_slot = nil;
	else
-- this one can't handle resolution switching and we ignore audio for the
-- time being or we'd need to do a lot of attachment tracking
		local isp = image_storage_properties(disp.rt);
		disp.share_slot = alloc_surface(isp.width, isp.height, true);
		local indir = null_surface(isp.width, isp.height);
		show_image(indir);
		image_sharestorage(disp.rt, indir);
		define_recordtarget(disp.share_slot,
		recfn, args, {indir}, {}, RENDERTARGET_DETACH, RENDERTARGET_NOSCALE, -1,
		function(src, status)
		end
		);
	end
end

-- the active displays is the rendertarget that will (initially) create new
-- windows, though they can be migrated immediately afterwards. This is because
-- both mouse_ implementation and new object attachment points are a global
-- state.
function active_display(rt, raw)
	if (raw) then
		return displays[displays.main];
	end

	if (not displays[displays.main]) then
		return;
	end

	if (rt) then
		return displays[displays.main].rt;
	else
		return displays[displays.main].tiler;
	end
end

	local function save_active_display()
		return displays.main;
end

--
-- These iterators are primarily for archetype handlers and similar where we
-- need "all windows regardless of display".  Don't break- out of this or
-- things may get the wrong attachment later.
--
local function aditer(rawdisp, showorph, showdis)
	local tbl = {};
	for i,v in ipairs(displays) do
		if ((not v.orphan or showorph) and (not v.disabled or showdis)) then
			table.insert(tbl, {i, v});
		end
	end
	local c = #tbl;
	local i = 0;
	local save = displays.main;

	return function()
		i = i + 1;
		if (i <= c) then
			switch_active_display(tbl[i][1]);
			return rawdisp and tbl[i][2] or tbl[i][2].tiler;
		else
			switch_active_display(save);
			return nil;
		end
	end
end

function all_tilers_iter()
	return aditer(false);
end

function all_displays_iter()
	return aditer(true);
end

function all_spaces_iter()
	local tbl = {};
	for i,v in ipairs(displays) do
		for k,l in pairs(v.tiler.spaces) do
			table.insert(tbl, {i,l});
		end
	end
	local c = #tbl;
	local i = 0;
	local save = displays.main;

	return function()
		i = i + 1;
		if (i <= c) then
			switch_active_display(tbl[i][1]);
			return tbl[i][2];
		else
			switch_active_display(save);
			return nil;
		end
	end
end

function all_windows(atype, noswitch)
	local tbl = {};
	for i,v in ipairs(displays) do
		for j,k in ipairs(v.tiler.windows) do
			table.insert(tbl, {i, k});
		end
	end

	local i = 0;
	local c = #tbl;
	local save = displays.main;

	return function()
		i = i + 1;
		while (i <= c) do
			if (not atype or (atype and tbl[i][2].atype == atype)) then
				if (not noswitch) then
					switch_active_display(tbl[i][1]);
				end
				return tbl[i][2];
			else
				i = i + 1;
			end
		end
		if (not noswitch) then
			switch_active_display(save);
		end
		return nil;
	end
end

function displays_alive(filter)
	local res = {};

	for k,v in ipairs(displays) do
		if (not (v.orphan or v.disabled) and (not filter or k ~= displays.main)) then
			table.insert(res, v.name);
		end
	end
	return res;
end

function display_tick()
	for k,v in ipairs(displays) do
		if (not v.orphan) then
			v.tiler:tick();
		end

-- periodically check source for dedicated fullscreen mode
		if (not displays.simple and v.monitor_vid) then

-- on death, set "BADID" (which will revert mapping to normal rt)
			if (not valid_vid(v.monitor_vid, TYPE_FRAMESERVER)) then
				display_fullscreen(v.name, BADID);
			else
				local isp = image_storage_properties(v.monitor_vid);

-- deferred resize- propagation due to cost of mode switch, this could probably
-- be even more conservative, though resolution switches in the source will
-- cause a visual glitch for the 'incorrect' frames.
				if (not v.monitor_sprops or isp.width ~= v.monitor_sprops.width or
					isp.height ~= v.monitor_sprops.height) then
					v.monitor_sprops = isp;
					if (v.fs_modesw) then
						set_best_mode(v, isp.width, isp.height);
					end
-- remap so crop-center works
				end
			end
		end
	end
end
